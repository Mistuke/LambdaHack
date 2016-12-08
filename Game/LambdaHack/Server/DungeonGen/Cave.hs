{-# LANGUAGE TupleSections #-}
-- | Generation of caves (not yet inhabited dungeon levels) from cave kinds.
module Game.LambdaHack.Server.DungeonGen.Cave
  ( Cave(..), bootFixedCenters, buildCave
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Key (mapWithKeyM)

import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.CaveKind
import Game.LambdaHack.Content.PlaceKind
import Game.LambdaHack.Content.TileKind (TileKind)
import Game.LambdaHack.Server.DungeonGen.Area
import Game.LambdaHack.Server.DungeonGen.AreaRnd
import Game.LambdaHack.Server.DungeonGen.Place

-- | The type of caves (not yet inhabited dungeon levels).
data Cave = Cave
  { dkind   :: !(Kind.Id CaveKind)  -- ^ the kind of the cave
  , dmap    :: !TileMapEM           -- ^ tile kinds in the cave
  , dplaces :: ![Place]             -- ^ places generated in the cave
  , dnight  :: !Bool                -- ^ whether the cave is dark
  }
  deriving Show

bootFixedCenters :: CaveKind -> [Point]
bootFixedCenters CaveKind{..} = [Point 4 3, Point (cxsize - 5) (cysize - 4)]

{-
Rogue cave is generated by an algorithm inspired by the original Rogue,
as follows:

  * The available area is divided into a grid, e.g, 3 by 3,
    where each of the 9 grid cells has approximately the same size.

  * In each of the 9 grid cells one room is placed at a random position
    and with a random size, but larger than The minimum size,
    e.g, 2 by 2 floor tiles.

  * Rooms that are on horizontally or vertically adjacent grid cells
    may be connected by a corridor. Corridors consist of 3 segments of straight
    lines (either "horizontal, vertical, horizontal" or "vertical, horizontal,
    vertical"). They end in openings in the walls of the room they connect.
    It is possible that one or two of the 3 segments have length 0, such that
    the resulting corridor is L-shaped or even a single straight line.

  * Corridors are generated randomly in such a way that at least every room
    on the grid is connected, and a few more might be. It is not sufficient
    to always connect all adjacent rooms.
-}
-- TODO: fix identifier naming and split, after the code grows some more
-- | Cave generation by an algorithm inspired by the original Rogue,
buildCave :: Kind.COps         -- ^ content definitions
          -> AbsDepth          -- ^ depth of the level to generate
          -> AbsDepth          -- ^ absolute depth
          -> Kind.Id CaveKind  -- ^ cave kind to use for generation
          -> EM.EnumMap Point (GroupName PlaceKind)  -- ^ pos of stairs, etc.
          -> Rnd Cave
buildCave cops@Kind.COps{ cotile=cotile@Kind.Ops{opick}
                        , cocave=Kind.Ops{okind}
                        , coTileSpeedup }
          ldepth totalDepth dkind fixedCenters = do
  let kc@CaveKind{..} = okind dkind
  lgrid' <- castDiceXY ldepth totalDepth cgrid
  -- Make sure that in caves not filled with rock, there is a passage
  -- across the cave, even if a single room blocks most of the cave.
  -- Also, ensure fancy outer fences are not obstructed by room walls.
  let fullArea = fromMaybe (assert `failure` kc)
                 $ toArea (0, 0, cxsize - 1, cysize - 1)
      subFullArea = fromMaybe (assert `failure` kc)
                    $ toArea (1, 1, cxsize - 2, cysize - 2)
  darkCorTile <- fromMaybe (assert `failure` cdarkCorTile)
                 <$> opick cdarkCorTile (const True)
  litCorTile <- fromMaybe (assert `failure` clitCorTile)
                <$> opick clitCorTile (const True)
  dnight <- chanceDice ldepth totalDepth cnightChance
  -- TODO: factor that out:
  let createPlaces lgr' = do
        let area | couterFenceTile /= "basic outer fence" = subFullArea
                 | otherwise = fullArea
            (lgr@(gx, gy), gs) =
              grid fixedCenters (bootFixedCenters kc) lgr' area
        minPlaceSize <- castDiceXY ldepth totalDepth cminPlaceSize
        maxPlaceSize <- castDiceXY ldepth totalDepth cmaxPlaceSize
        let mergeFixed :: EM.EnumMap Point SpecialArea
                       -> (Point, SpecialArea)
                       -> (EM.EnumMap Point SpecialArea)
            mergeFixed !gs0 (!i, !special) =
              let mergeSpecial ar p2 f =
                    case EM.lookup p2 gs0 of
                      Just (SpecialArea ar2) ->
                        let aSum = sumAreas ar ar2
                            sp = SpecialMerged (f aSum) p2
                        in EM.insert i sp $ EM.delete p2 gs0
                      _ -> gs0
                  mergable :: X -> Y -> Maybe HV
                  mergable x y | x < 0 || y < 0 = Nothing
                               | otherwise = case EM.lookup (Point x y) gs0 of
                    Just (SpecialArea ar) ->
                      let (x0, y0, x1, y1) = fromArea ar
                          isFixed p = case gs EM.! p of
                            SpecialFixed{} -> True
                            _ -> False
                      in if | any isFixed
                              $ vicinityCardinal gx gy (Point x y) -> Nothing
                              -- Bias: prefer extending vertically.
                            | y1 - y0 - 1 < snd minPlaceSize -> Just Vert
                            | x1 - x0 - 1 < fst minPlaceSize -> Just Horiz
                            | otherwise -> Nothing
                    _ -> Nothing
              in case special of
                SpecialArea ar -> case mergable (px i) (py i) of
                  Nothing -> gs0
                  Just hv -> case hv of
                    -- Bias; vertical minimal sizes are smaller.
                    Vert | mergable (px i) (py i - 1) == Just Vert ->
                           mergeSpecial ar i{py = py i - 1} SpecialArea
                    Vert | mergable (px i) (py i + 1) == Just Vert ->
                           mergeSpecial ar i{py = py i + 1} SpecialArea
                    Horiz | mergable (px i - 1) (py i) == Just Horiz ->
                            mergeSpecial ar i{px = px i - 1} SpecialArea
                    Horiz | mergable (px i + 1) (py i) == Just Horiz ->
                            mergeSpecial ar i{px = px i + 1} SpecialArea
                    _ -> gs0
                SpecialFixed p placeGroup ar ->
                  let (x0, y0, x1, y1) = fromArea ar
                      d = 3
                      vics = [i {py = py i - 1} | py p - y0 < d]
                             ++ [i {py = py i + 1} | y1 - py p < d]
                             ++ [i {px = px i - 1} | px p - x0 < d + 1]
                             ++ [i {px = px i + 1} | x1 - px p < d + 1]
                  in case vics of
                    [p2] -> mergeSpecial ar p2 (SpecialFixed p placeGroup)
                    _ -> gs0
                SpecialMerged{} -> assert `failure` (gs, gs0, i)
            gs2 = foldl' mergeFixed gs $ EM.assocs gs
        voidPlaces <-
          let gridArea = fromMaybe (assert `failure` lgr)
                         $ toArea (0, 0, gx - 1, gy - 1)
              voidNum = round $ cmaxVoid * fromIntegral (EM.size gs2)
          in ES.fromList <$> replicateM voidNum (xyInArea gridArea)
                   -- repetitions are OK; variance is low anyway
        let decidePlace :: Bool
                        -> ( TileMapEM, [Place]
                           , EM.EnumMap Point (Area, Area, Area) )
                        -> (Point, SpecialArea)
                        -> Rnd ( TileMapEM, [Place]
                               , EM.EnumMap Point (Area, Area, Area) )
            decidePlace noVoid (!m, !pls, !qls) (!i, !special) = do
              case special of
                SpecialArea ar -> do
                  -- Reserved for corridors and the global fence.
                  let innerArea = fromMaybe (assert `failure` (i, ar))
                                  $ shrink ar
                      !_A0 = shrink innerArea
                      !_A1 = assert (isJust _A0 `blame` (innerArea, gs2)) ()
                  if not noVoid && i `ES.member` voidPlaces
                  then do
                    r <- mkVoidRoom innerArea
                    return (m, pls, EM.insert i (r, r, ar) qls)
                  else do
                    r <- mkRoom minPlaceSize maxPlaceSize innerArea
                    (tmap, place) <-
                      buildPlace cops kc dnight darkCorTile litCorTile
                                 ldepth totalDepth r Nothing
                    let (sa, so) = borderPlace cops place
                    return ( EM.union tmap m
                           , place : pls
                           , EM.insert i (sa, so, ar) qls )
                SpecialFixed p@Point{..} placeGroup ar -> do
                  -- Reserved for corridors and the global fence.
                  let innerArea = fromMaybe (assert `failure` (i, ar))
                                  $ shrink ar
                      !_A0 = shrink innerArea
                      !_A1 = assert (isJust _A0 `blame` (innerArea, gs2)) ()
                      !_A2 = assert (p `inside` fromArea (fromJust _A0)
                                     `blame` (p, innerArea, fixedCenters)) ()
                      r = mkFixed maxPlaceSize innerArea p
                      !_A3 = assert (isJust (shrink r)
                                     `blame` ( r, p, innerArea, ar
                                             , gs2, qls, fixedCenters )) ()
                  (tmap, place) <-
                    buildPlace cops kc dnight darkCorTile litCorTile
                               ldepth totalDepth r (Just placeGroup)
                  let (sa, so) = borderPlace cops place
                  return ( EM.union tmap m
                         , place : pls
                         , EM.insert i (sa, so, ar) qls )
                SpecialMerged sp p2 -> do
                  (lplaces, dplaces, qplaces) <-
                    decidePlace True (m, pls, qls) (i, sp)
                  return ( lplaces, dplaces
                         , EM.insert p2 (qplaces EM.! i) qplaces )
        places <- foldlM' (decidePlace False) (EM.empty, [], EM.empty)
                  $ EM.assocs gs2
        return (voidPlaces, lgr, places)
  (voidPlaces, lgrid, (lplaces, dplaces, qplaces)) <- createPlaces lgrid'
  let lcorridorsFun lgr = do
        connects <- connectGrid lgr
        addedConnects <- do
          let cauxNum =
                round $ cauxConnects * fromIntegral (fst lgr * snd lgrid)
          cns <- replicateM cauxNum (randomConnection lgr)
          return $! filter (\(p, q) -> p `ES.notMember` voidPlaces
                                       && q `ES.notMember` voidPlaces) cns
        let allConnects =
              connects `union` nub (sort addedConnects)  -- duplicates removed
            connectPos :: (Point, Point) -> Rnd (Maybe Corridor)
            connectPos (p0, p1) =
              connectPlaces (qplaces EM.! p0) (qplaces EM.! p1)
        cs <- catMaybes <$> mapM connectPos allConnects
        let pickedCorTile = if dnight then darkCorTile else litCorTile
        return $! EM.unions (map (digCorridors pickedCorTile) cs)
  lcorridors <- lcorridorsFun lgrid
  let doorMapFun lpl lcor = do
        -- The hacks below are instead of unionWithKeyM, which is costly.
        let mergeCor _ pl cor = if Tile.isWalkable coTileSpeedup pl
                                then Nothing  -- tile already open
                                else Just (Tile.hideAs cotile pl, cor)
            intersectionWithKeyMaybe combine =
              EM.mergeWithKey combine (const EM.empty) (const EM.empty)
            interCor = intersectionWithKeyMaybe mergeCor lpl lcor  -- fast
        mapWithKeyM (pickOpening cops kc lplaces litCorTile)
                    interCor  -- very small
  doorMap <- doorMapFun lplaces lcorridors
  fence <- buildFenceRnd cops couterFenceTile subFullArea
  let dmap = EM.unions [doorMap, lplaces, lcorridors, fence]  -- order matters
  return $! Cave {dkind, dmap, dplaces, dnight}

borderPlace :: Kind.COps -> Place -> (Area, Area)
borderPlace Kind.COps{coplace=Kind.Ops{okind}} Place{..} =
  case pfence (okind qkind) of
    FWall -> (qarea, qarea)
    FFloor  -> (qarea, expand qarea)
    FGround -> (qarea, expand qarea)
    FNone -> case shrink qarea of
      Nothing -> (qarea, qarea)
      Just sr -> (sr, qarea)

pickOpening :: Kind.COps -> CaveKind -> TileMapEM -> Kind.Id TileKind
            -> Point -> (Kind.Id TileKind, Kind.Id TileKind)
            -> Rnd (Kind.Id TileKind)
pickOpening Kind.COps{cotile, coTileSpeedup}
            CaveKind{cxsize, cysize, cdoorChance, copenChance}
            lplaces litCorTile
            pos (hidden, cor) = do
  let nicerCorridor =
        if Tile.isLit coTileSpeedup cor then cor
        else -- If any cardinally adjacent room tile lit, make the opening lit.
             let roomTileLit p =
                   case EM.lookup p lplaces of
                     Nothing -> False
                     Just tile -> Tile.isLit coTileSpeedup tile
                 vic = vicinityCardinal cxsize cysize pos
             in if any roomTileLit vic then litCorTile else cor
  -- Openings have a certain chance to be doors and doors have a certain
  -- chance to be open.
  rd <- chance cdoorChance
  if rd then do
    doorClosedId <- Tile.revealAs cotile hidden
    -- Not all solid tiles can hide a door.
    if Tile.isDoor coTileSpeedup doorClosedId then do  -- door created
      ro <- chance copenChance
      if ro then Tile.openTo cotile doorClosedId
      else return $! doorClosedId
    else return $! nicerCorridor
  else return $! nicerCorridor

digCorridors :: Kind.Id TileKind -> Corridor -> TileMapEM
digCorridors tile (p1:p2:ps) =
  EM.union corPos (digCorridors tile (p2:ps))
 where
  cor  = fromTo p1 p2
  corPos = EM.fromList $ zip cor (repeat tile)
digCorridors _ _ = EM.empty
