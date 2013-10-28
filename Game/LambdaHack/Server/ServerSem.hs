{-# LANGUAGE OverloadedStrings #-}
-- | Semantics of 'CmdSer' server commands.
-- A couple of them do not take time, the rest does.
-- Note that since the results are atomic commands, which are executed
-- only later (on the server and some of the clients), all condition
-- are checkd by the semantic functions in the context of the state
-- before the server command. Even if one or more atomic actions
-- are already issued by the point an expression is evaluated, they do not
-- influence the outcome of the evaluation.
-- TODO: document
module Game.LambdaHack.Server.ServerSem where

import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.Key (mapWithKeyM_)
import Data.Maybe
import Data.Ratio
import Data.Text (Text)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Common.Action
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.AtomicCmd
import qualified Game.LambdaHack.Common.Color as Color
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.ServerCmd
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.ItemKind
import Game.LambdaHack.Content.TileKind as TileKind
import Game.LambdaHack.Server.Action hiding (sendQueryAI, sendQueryUI,
                                      sendUpdateAI, sendUpdateUI)
import Game.LambdaHack.Server.Config
import Game.LambdaHack.Server.EffectSem
import Game.LambdaHack.Server.State
import Game.LambdaHack.Utils.Assert

execFailure :: (MonadAtomic m, MonadServer m)
            => Actor -> FailureSer -> m ()
execFailure body failureSer = do
  -- Clients should rarely do that (only in case of invisible actors)
  -- so we report it, send a --more-- meeesage (if not AI), but do not crash
  -- (server should work OK with stupid clients, too).
  let fid = bfid body
      msg = showFailureSer failureSer
  debugPrint $ "execFailure:" <+> showT fid <+> ":" <+> msg
  execSfxAtomic $ MsgFidD fid msg  -- TODO: --more--

broadcastCmdAtomic :: MonadAtomic m
                   => (FactionId -> CmdAtomic) -> m ()
broadcastCmdAtomic fcmd = do
  factionD <- getsState sfactionD
  mapWithKeyM_ (\fid _ -> execCmdAtomic $ fcmd fid) factionD

broadcastSfxAtomic :: MonadAtomic m
                   => (FactionId -> SfxAtomic) -> m ()
broadcastSfxAtomic fcmd = do
  factionD <- getsState sfactionD
  mapWithKeyM_ (\fid _ -> execSfxAtomic $ fcmd fid) factionD

-- * MoveSer

-- TODO: let only some actors/items leave smell, e.g., a Smelly Hide Armour.
-- | Add a smell trace for the actor to the level. For now, all and only
-- actors from non-spawning factions leave smell.
addSmell :: MonadAtomic m => ActorId -> m ()
addSmell aid = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  b <- getsState $ getActorBody aid
  spawn <- getsState $ isSpawnFaction (bfid b)
  let canSmell = asmell $ okind $ bkind b
  unless (bproj b || spawn || canSmell) $ do
    time <- getsState $ getLocalTime $ blid b
    oldS <- getsLevel (blid b) $ EM.lookup (bpos b) . lsmell
    let newTime = timeAdd time smellTimeout
    execCmdAtomic $ AlterSmellA (blid b) (bpos b) oldS (Just newTime)

-- | Resolves the result of an actor moving into another.
-- Actors on blocked positions can be attacked without any restrictions.
-- For instance, an actor embedded in a wall can be attacked from
-- an adjacent position. This function is analogous to projectGroupItem,
-- but for melee and not using up the weapon.
actorAttackActor :: (MonadAtomic m, MonadServer m)
                 => ActorId -> ActorId -> m ()
actorAttackActor source target = do
  cops@Kind.COps{coitem=Kind.Ops{opick, okind}} <- getsState scops
  sb <- getsState (getActorBody source)
  tb <- getsState (getActorBody target)
  let sfid = bfid sb
      tfid = bfid tb
  time <- getsState $ getLocalTime (blid tb)
  s <- getState
  itemAssocs <- getsState $ getActorItem source
  (miid, item) <-
    if bproj sb
    then case itemAssocs of
      [(iid, item)] -> return (Just iid, item)  -- projectile
      _ -> assert `failure` itemAssocs
    else case strongestSword cops itemAssocs of
      Just (_, (iid, w)) -> return (Just iid, w)
      Nothing -> do  -- hand to hand combat
        let h2hGroup | isSpawnFaction sfid s = "monstrous"
                     | otherwise = "unarmed"
        h2hKind <- rndToAction $ opick h2hGroup (const True)
        flavour <- getsServer sflavour
        discoRev <- getsServer sdiscoRev
        let kind = okind h2hKind
            effect = fmap (maxDice . fst) (ieffect kind)
        return ( Nothing
               , buildItem flavour discoRev h2hKind kind effect )
  let performHit block = do
        let hitA = if block then HitBlockD else HitD
        execSfxAtomic $ StrikeD source target item hitA
        -- Deduct a hitpoint for a pierce of a projectile.
        when (bproj sb) $ execCmdAtomic $ HealActorA source (-1)
        -- Msgs inside itemEffectSem describe the target part.
        itemEffect source target miid item
  -- Projectiles can't be blocked (though can be sidestepped).
  -- Incapacitated actors can't block
  if braced tb time && not (bproj sb) && bhp tb > 0
    then do
      blocked <- rndToAction $ chance $ 1%2
      if blocked
        then execSfxAtomic $ StrikeD source target item MissBlockD
        else performHit True
    else performHit False
  sfact <- getsState $ (EM.! sfid) . sfactionD
  -- The only way to start a war is to slap an enemy. Being hit by
  -- and hitting projectiles count as unintentional friendly fire.
  let friendlyFire = bproj sb || bproj tb
      fromDipl = EM.findWithDefault Unknown tfid (gdipl sfact)
  unless (friendlyFire || isAtWar sfact tfid || sfid == tfid) $
    execCmdAtomic $ DiplFactionA sfid tfid fromDipl War

-- | Actor moves or attacks.
-- Note that client may not be able to see an invisible monster
-- so it's the server that determines if melee took place, etc.
-- Also, only the server is authorized to check if a move is legal
-- and it needs full context for that, e.g., the initial actor position
-- to check if melee attack does not try to reach to a distant tile.
moveSer :: (MonadAtomic m, MonadServer m) => ActorId -> Vector -> m ()
moveSer aid dir = do
  cops <- getsState scops
  sb <- getsState $ getActorBody aid
  let lid = blid sb
  lvl <- getsLevel lid id
  let spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
  -- We start by checking actors at the the target position.
  tgt <- getsState (posToActor tpos lid)
  case tgt of
    Just target ->  -- visible or not
      -- Attacking does not require full access, adjacency is enough.
      actorAttackActor aid target
    Nothing
      | accessible cops lvl spos tpos -> do
          -- Movement requires full access.
          execCmdAtomic $ MoveActorA aid spos tpos
          addSmell aid
      | otherwise ->
          -- Client foolishly tries to move into blocked, boring tile.
          execFailure sb MoveNothing

-- * DisplaceSer

-- | Actor tries to swap positions with another.
displaceSer :: (MonadAtomic m, MonadServer m) => ActorId -> Vector -> m ()
displaceSer aid dir = do
  cops <- getsState scops
  sb <- getsState $ getActorBody aid
  let lid = blid sb
  lvl <- getsLevel lid id
  let spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
  -- We start by checking actors at the the target position.
  tgt <- getsState (posToActor tpos lid)
  case tgt of
    Just target
      | accessible cops lvl spos tpos -> do
          -- Displacing requires full access.
          execCmdAtomic $ DisplaceActorA aid target
          addSmell aid
      | otherwise ->
          -- Client foolishly tries to displace an actor without access.
          execFailure sb RunDisplaceAccess
    Nothing ->
      -- Client foolishly tries to displace an empty tile.
      execFailure sb RunNothing

-- * AlterSer

-- | Search and/or alter the tile.
--
-- Note that if @serverTile /= freshClientTile@, @freshClientTile@
-- should not be alterable (but @serverTile@ may be).
alterSer :: (MonadAtomic m, MonadServer m)
         => ActorId -> Vector -> Maybe F.Feature -> m ()
alterSer aid dir mfeat = do
  Kind.COps{cotile=cotile@Kind.Ops{okind, opick}} <- getsState scops
  sb <- getsState $ getActorBody aid
  let lid = blid sb
  lvl <- getsLevel lid id
  let spos = bpos sb           -- source position
      tpos = spos `shift` dir  -- target position
      serverTile = lvl `at` tpos
      freshClientTile = hideTile cotile tpos lvl
      changeTo tgroup = do
        -- No AlterD, because the effect is obvious (e.g., opened door).
        toTile <- rndToAction $ opick tgroup (const True)
        execCmdAtomic $ AlterTileA lid tpos serverTile toTile
        return True
      alterFeat feat =
        case feat of
          F.OpenTo tgroup -> changeTo tgroup
          F.CloseTo tgroup -> changeTo tgroup
          F.ChangeTo tgroup -> changeTo tgroup
          _ -> return False
      feats = case mfeat of
        Nothing -> TileKind.tfeature $ okind serverTile
        Just feat2 | Tile.hasFeature cotile feat2 serverTile -> [feat2]
        Just _ -> []
  as <- getsState $ actorList (const True) lid
  if EM.null $ lvl `atI` tpos then
    if unoccupied as tpos then do
      if serverTile /= freshClientTile then do
        -- Search, in case some actors (of other factions?)
        -- don't know this tile.
        execCmdAtomic $ SearchTileA aid tpos freshClientTile serverTile
        mapM_ alterFeat feats
        -- Even if no effect, at least we possibly searched something,
        -- so we don't report Failure.
      else do
        bs <- mapM alterFeat feats
        when (not $ or bs) $
          -- Neither searching nor altering possible; silly client.
          execFailure sb AlterNothing
    else execFailure sb AlterBlockActor
  else execFailure sb AlterBlockItem

-- * WaitSer

-- | Update the wait/block count. Uses local, per-level time,
-- to remain correct even if the level is frozen for some global time turns.
waitSer :: MonadAtomic m => ActorId -> m ()
waitSer aid = do
  Kind.COps{coactor} <- getsState scops
  body <- getsState $ getActorBody aid
  time <- getsState $ getLocalTime $ blid body
  let fromWait = bwait body
      toWait = timeAddFromSpeed coactor body time
  execCmdAtomic $ WaitActorA aid fromWait toWait

-- * PickupSer

pickupSer :: MonadAtomic m
          => ActorId -> ItemId -> Int -> InvChar -> m ()
pickupSer aid iid k l = assert (k > 0 `blame` (aid, iid, k, l)) $ do
  b <- getsState $ getActorBody aid
  execCmdAtomic $ MoveItemA iid k (CFloor (blid b) (bpos b)) (CActor aid l)

-- * DropSer

dropSer :: MonadAtomic m => ActorId -> ItemId -> m ()
dropSer aid iid = do
  b <- getsState $ getActorBody aid
  let k = 1
  execCmdAtomic $ MoveItemA iid k (actorContainer aid (binv b) iid)
                                  (CFloor (blid b) (bpos b))

-- * ProjectSer

projectSer :: (MonadAtomic m, MonadServer m)
           => ActorId    -- ^ actor projecting the item (is on current lvl)
           -> Point      -- ^ target position of the projectile
           -> Int        -- ^ digital line parameter
           -> ItemId     -- ^ the item to be projected
           -> Container  -- ^ whether the items comes from floor or inventory
           -> m ()
projectSer source tpos eps iid container = do
  Kind.COps{cotile} <- getsState scops
  sb <- getsState $ getActorBody source
  let lid = blid sb
      spos = bpos sb
  fact <- getsState $ (EM.! bfid sb) . sfactionD
  bs <- getsState $ actorNotProjList (isAtWar fact) lid
  lxsize <- getsLevel lid lxsize
  lysize <- getsLevel lid lysize
  if foesAdjacent lxsize lysize spos bs
    then execFailure sb ProjectBlockFoes
    else do
      case bla lxsize lysize eps spos tpos of
        Nothing -> execFailure sb ProjectAimOnself
        Just [] -> assert `failure`
                     (spos, tpos, "project from the edge of level" :: Text)
        Just (pos : rest) -> do
          inhabitants <- getsState (posToActor pos lid)
          lvl <- getsLevel lid id
          let t = lvl `at` pos
          if not $ Tile.hasFeature cotile F.Clear t
            then execFailure sb ProjectBlockTerrain
            else if isJust inhabitants
                 then execFailure sb ProjectBlockActor
                 else projectBla source pos rest iid container

projectBla :: (MonadAtomic m, MonadServer m)
           => ActorId    -- ^ actor projecting the item (is on current lvl)
           -> Point      -- ^ starting point of the projectile
           -> [Point]    -- ^ rest of the path of the projectile
           -> ItemId     -- ^ the item to be projected
           -> Container  -- ^ whether the items comes from floor or inventory
           -> m ()
projectBla source pos rest iid container = do
  sb <- getsState $ getActorBody source
  let lid = blid sb
      -- A bit later than actor time, to prevent a move this turn.
      time = btime sb `timeAdd` timeEpsilon
  execSfxAtomic $ ProjectD source iid
  projId <- addProjectile pos rest iid lid (bfid sb) time
  execCmdAtomic $ MoveItemA iid 1 container (CActor projId (InvChar 'a'))

-- | Create a projectile actor containing the given missile.
addProjectile :: (MonadAtomic m, MonadServer m)
              => Point -> [Point] -> ItemId -> LevelId -> FactionId -> Time
              -> m ActorId
addProjectile bpos rest iid blid bfid btime = do
  Kind.COps{coactor, coitem=coitem@Kind.Ops{okind}} <- getsState scops
  disco <- getsServer sdisco
  item <- getsState $ getItemBody iid
  let ik = okind (fromJust $ jkind disco item)
      speed = speedFromWeight (iweight ik) (itoThrow ik)
      range = rangeFromSpeed speed
      adj | range < 5 = "falling"
          | otherwise = "flying"
      -- Not much details about a fast flying object.
      (object1, object2) = partItem coitem EM.empty item
      name = makePhrase [MU.AW $ MU.Text adj, object1, object2]
      dirPath = take range $ displacePath (bpos : rest)
      m = actorTemplate (projectileKindId coactor) Nothing (Just name) Nothing
                        (Just speed) 0 (Just dirPath) bpos blid btime bfid True
  acounter <- getsServer sacounter
  modifyServer $ \ser -> ser {sacounter = succ acounter}
  execCmdAtomic $ CreateActorA acounter m [(iid, item)]
  return acounter

-- * ApplySer

applySer :: (MonadAtomic m, MonadServer m)
         => ActorId    -- ^ actor applying the item (is on current level)
         -> ItemId     -- ^ the item to be applied
         -> Container  -- ^ the location of the item
         -> m ()
applySer actor iid container = do
  item <- getsState $ getItemBody iid
  execSfxAtomic $ ActivateD actor iid
  itemEffect actor actor (Just iid) item
  -- TODO: don't destroy if not really used up; also, don't take time?
  execCmdAtomic $ DestroyItemA iid item 1 container

-- * TriggerSer

-- | Perform the action specified for the tile in case it's triggered.
triggerSer :: (MonadAtomic m, MonadServer m)
           => ActorId -> Maybe F.Feature -> m ()
triggerSer aid mfeat = do
  Kind.COps{cotile=cotile@Kind.Ops{okind}} <- getsState scops
  sb <- getsState $ getActorBody aid
  let lid = blid sb
  lvl <- getsLevel lid id
  let tpos = bpos sb
      serverTile = lvl `at` tpos
      triggerFeat feat =
        case feat of
          F.Cause ef -> do
            -- No block against tile, hence unconditional.
            execSfxAtomic $ TriggerD aid tpos feat
            void $ effectSem ef aid aid
            return True
          _ -> return False
      feats = case mfeat of
        Nothing -> TileKind.tfeature $ okind serverTile
        Just feat2 | Tile.hasFeature cotile feat2 serverTile -> [feat2]
        Just _ -> []
  bs <- mapM triggerFeat feats
  when (not $ or bs) $ execFailure sb TriggerNothing

-- * SetPathSer

setPathSer :: (MonadAtomic m, MonadServer m)
           => ActorId -> [Vector] -> m ()
setPathSer aid path = do
  when (length path <= 2) $ do
    fromColor <- getsState $ bcolor . getActorBody aid
    let toColor = Just Color.BrBlack
    when (fromColor /= toColor) $
      execCmdAtomic $ ColorActorA aid fromColor toColor
  fromPath <- getsState $ bpath . getActorBody aid
  case path of
    [] -> execCmdAtomic $ PathActorA aid fromPath (Just [])
    d : lv -> do
      void $ moveSer aid d
      execCmdAtomic $ PathActorA aid fromPath (Just lv)

-- * GameRestart

gameRestartSer :: (MonadAtomic m, MonadServer m) => ActorId -> Text -> m ()
gameRestartSer aid stInfo = do
  b <- getsState $ getActorBody aid
  let fid = bfid b
  oldSt <- getsState $ gquit . (EM.! fid) . sfactionD
  modifyServer $ \ser -> ser {squit = True}  -- do this at once
  revealItems Nothing Nothing
  execCmdAtomic $ QuitFactionA fid (Just b) oldSt
                $ Just $ Status Restart (fromEnum $ blid b) stInfo

-- * GameExit

gameExitSer :: (MonadAtomic m, MonadServer m) => ActorId -> m ()
gameExitSer aid = do
  b <- getsState $ getActorBody aid
  let fid = bfid b
  oldSt <- getsState $ gquit . (EM.! fid) . sfactionD
  modifyServer $ \ser -> ser {squit = True}  -- do this at once
  execCmdAtomic $ QuitFactionA fid (Just b) oldSt
                $ Just $ Status Camping (fromEnum $ blid b) ""

-- * GameSaveSer

gameSaveSer :: MonadServer m => m ()
gameSaveSer = do
  modifyServer $ \ser -> ser {sbkpSave = True}
  modifyServer $ \ser -> ser {squit = True}  -- do this at once

-- * CfgDumpSer

cfgDumpSer :: (MonadAtomic m, MonadServer m) => ActorId -> m ()
cfgDumpSer aid = do
  b <- getsState $ getActorBody aid
  let fid = bfid b
  Config{configRulesCfgFile} <- getsServer sconfig
  let fn = configRulesCfgFile ++ ".dump"
      msg = "Server dumped current game rules configuration to file"
            <+> T.pack fn <> "."
  dumpCfg fn
  -- Wait with confirmation until saved; tell where the file is.
  execSfxAtomic $ MsgFidD fid msg
