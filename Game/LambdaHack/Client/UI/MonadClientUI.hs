-- | Client monad for interacting with a human through UI.
module Game.LambdaHack.Client.UI.MonadClientUI
  ( -- * Client UI monad
    MonadClientUI( getSession, getsSession, modifySession, putSession
                 , liftIO  -- exposed only to be implemented, not used,
                 )
    -- * Assorted primitives
  , mapStartY, displayFrame, displayActorStart
  , setFrontAutoYes, anyKeyPressed, discardPressedKey, addPressedKey
  , connFrontendFrontKey, frontendShutdown, chanFrontend
  , getReportUI, getLeaderUI, getArenaUI, viewedLevelUI
  , leaderTgtToPos, leaderTgtAims, xhairToPos
  , scoreToSlideshow, defaultHistory
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import qualified Data.EnumMap.Strict as EM
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Time.LocalTime
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.CommonM
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient hiding (liftIO)
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Frame
import Game.LambdaHack.Client.UI.Frontend
import qualified Game.LambdaHack.Client.UI.Frontend as Frontend
import Game.LambdaHack.Client.UI.Msg
import Game.LambdaHack.Client.UI.Overlay
import Game.LambdaHack.Client.UI.SessionUI
import Game.LambdaHack.Client.UI.Slideshow
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.ClientOptions
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.HighScore as HighScore
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ModeKind

-- | The row where the dungeon map starts.
mapStartY :: Y
mapStartY = 1

-- | The monad that gives the client access to UI operations.
class MonadClient m => MonadClientUI m where
  getSession  :: m SessionUI
  getsSession  :: (SessionUI -> a) -> m a
  modifySession :: (SessionUI -> SessionUI) -> m ()
  putSession  :: SessionUI -> m ()
  liftIO        :: IO a -> m a

-- | Write a UI request to the frontend and read a corresponding reply.
connFrontend :: MonadClientUI m => FrontReq a -> m a
connFrontend req = do
  ChanFrontend f <- getsSession schanF
  liftIO $ f req

displayFrame :: MonadClientUI m => Maybe SingleFrame -> m ()
displayFrame mf = do
  let frame = case mf of
        Nothing -> FrontDelay 1
        Just fr -> FrontFrame fr
  connFrontend frame

-- | Push frames or delays to the frame queue.
displayActorStart :: MonadClientUI m => Actor -> Frames -> m ()
displayActorStart b frs = do
  mapM_ displayFrame frs
  -- Can be different than @blid b@, e.g., when our actor is attacked
  -- on a remote level.
  arena <- getArenaUI
  when (arena == blid b) $
    modifySession $ \sess -> sess {sdisplayNeeded = False}

-- | Write 'FrontKey' UI request to the frontend, read the reply,
-- set pointer, return key.
connFrontendFrontKey :: MonadClientUI m => [K.KM] -> SingleFrame -> m K.KM
connFrontendFrontKey frontKeyKeys frontKeyFrame = do
  kmp <- connFrontend $ FrontKey{..}
  modifySession $ \sess -> sess {spointer = kmpPointer kmp}
  return $! kmpKeyMod kmp

setFrontAutoYes :: MonadClientUI m => Bool -> m ()
setFrontAutoYes b = connFrontend $ FrontAutoYes b

anyKeyPressed :: MonadClientUI m => m Bool
anyKeyPressed = connFrontend FrontPressed

discardPressedKey :: MonadClientUI m => m ()
discardPressedKey = connFrontend FrontDiscard

addPressedKey :: MonadClientUI m => KMP -> m ()
addPressedKey = connFrontend . FrontAdd

frontendShutdown :: MonadClientUI m => m ()
frontendShutdown = connFrontend FrontShutdown

chanFrontend :: MonadClientUI m => DebugModeCli -> m ChanFrontend
chanFrontend = liftIO . Frontend.chanFrontendIO

getReportUI :: MonadClientUI m => m Report
getReportUI = do
  report <- getsSession _sreport
  side <- getsClient sside
  fact <- getsState $ (EM.! side) . sfactionD
  let underAI = isAIFact fact
      promptAI = toPrompt $ toAttrLine $ "[press any key for Main Menu]"
  return $! if underAI then consReport promptAI report else report

getLeaderUI :: MonadClientUI m => m ActorId
getLeaderUI = do
  cli <- getClient
  case _sleader cli of
    Nothing -> assert `failure` "leader expected but not found" `twith` cli
    Just leader -> return leader

getArenaUI :: MonadClientUI m => m LevelId
getArenaUI = do
  mleader <- getsClient _sleader
  case mleader of
    Just leader -> getsState $ blid . getActorBody leader
    Nothing -> do
      side <- getsClient sside
      fact <- getsState $ (EM.! side) . sfactionD
      case gquit fact of
        Just Status{stDepth} -> return $! toEnum stDepth
        Nothing -> getEntryArena fact

viewedLevelUI :: MonadClientUI m => m LevelId
viewedLevelUI = do
  arena <- getArenaUI
  saimMode <- getsSession saimMode
  return $! maybe arena aimLevelId saimMode

leaderTgtToPos :: MonadClientUI m => m (Maybe Point)
leaderTgtToPos = do
  lidV <- viewedLevelUI
  mleader <- getsClient _sleader
  case mleader of
    Nothing -> return Nothing
    Just aid -> do
      tgt <- getsClient $ getTarget aid
      aidTgtToPos aid lidV tgt

leaderTgtAims :: MonadClientUI m => m (Either Text Int)
leaderTgtAims = do
  lidV <- viewedLevelUI
  mleader <- getsClient _sleader
  case mleader of
    Nothing -> return $ Left "no leader to aim with"
    Just aid -> do
      tgt <- getsClient $ getTarget aid
      aidTgtAims aid lidV tgt

xhairToPos :: MonadClientUI m => m (Maybe Point)
xhairToPos = do
  lidV <- viewedLevelUI
  mleader <- getsClient _sleader
  sxhair <- getsClient sxhair
  case mleader of
    Nothing -> return Nothing
    Just aid -> aidTgtToPos aid lidV $ Just sxhair

scoreToSlideshow :: MonadClientUI m => Int -> Status -> m Slideshow
scoreToSlideshow total status = do
  arena <- getArenaUI
  Level{lxsize, lysize} <- getLevel arena
  fid <- getsClient sside
  fact <- getsState $ (EM.! fid) . sfactionD
  -- TODO: Re-read the table in case it's changed by a concurrent game.
  -- TODO: we should do this, and make sure we do that after server
  -- saved the updated score table, and not register, but read from it.
  -- Otherwise the score is not accurate, e.g., the number of victims.
  scoreDict <- getsState shigh
  gameModeId <- getsState sgameModeId
  gameMode <- getGameMode
  time <- getsState stime
  date <- liftIO getPOSIXTime
  tz <- liftIO $ getTimeZone $ posixSecondsToUTCTime date
  scurDiff <- getsClient scurDiff
  factionD <- getsState sfactionD
  let table = HighScore.getTable gameModeId scoreDict
      gameModeName = mname gameMode
      diff | fhasUI $ gplayer fact = scurDiff
           | otherwise = difficultyInverse scurDiff
      theirVic (fi, fa) | isAtWar fact fi
                          && not (isHorrorFact fa) = Just $ gvictims fa
                        | otherwise = Nothing
      theirVictims = EM.unionsWith (+) $ mapMaybe theirVic $ EM.assocs factionD
      ourVic (fi, fa) | isAllied fact fi || fi == fid = Just $ gvictims fa
                      | otherwise = Nothing
      ourVictims = EM.unionsWith (+) $ mapMaybe ourVic $ EM.assocs factionD
      (worthMentioning, (ntable, pos)) =
        HighScore.register table total time status date diff
                           (fname $ gplayer fact)
                           ourVictims theirVictims
                           (fhiCondPoly $ gplayer fact)
      (msg, tts) = HighScore.highSlideshow ntable pos gameModeName tz
      al = toAttrLine msg
      splitScreen ts =
        splitOKX lxsize (lysize + 3) al [K.spaceKM, K.escKM] (ts, [])
      sli = toSlideshow $ concat $ map (splitScreen . map toAttrLine) tts
  return $! if worthMentioning
            then sli
            else emptySlideshow

defaultHistory :: MonadClientUI m => Int -> m History
defaultHistory configHistoryMax = liftIO $ do
  utcTime <- getCurrentTime
  timezone <- getTimeZone utcTime
  let curDate = MU.Text $ tshow $ utcToLocalTime timezone utcTime
  let emptyHist = emptyHistory configHistoryMax
  return $! addReport emptyHist timeZero
         $ singletonReport $ toMsg $ toAttrLine
         $ makeSentence ["Human history log started on", curDate]
