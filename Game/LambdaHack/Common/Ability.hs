{-# LANGUAGE DeriveGeneric #-}
-- | AI strategy abilities.
module Game.LambdaHack.Common.Ability
  ( Ability(..), Skills
  , zeroSkills, unitSkills, addSkills, scaleSkills, tacticSkills
  , blockOnly, meleeAdjacent, meleeAndRanged, ignoreItems
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import           Control.DeepSeq
import           Data.Binary
import qualified Data.EnumMap.Strict as EM
import           Data.Hashable (Hashable)
import           GHC.Generics (Generic)

import Game.LambdaHack.Common.Misc

-- | Actor and faction abilities corresponding to client-server requests.
data Ability =
  -- Basic abilities affecting permitted actions.
    AbMove
  | AbMelee
  | AbDisplace
  | AbAlter
  | AbWait
  | AbMoveItem
  | AbProject
  | AbApply
  -- Assorted abilities.
  | AbHurtMelee    -- ^ percentage damage bonus in melee
  | AbArmorMelee   -- ^ percentage armor bonus against melee
  | AbArmorRanged  -- ^ percentage armor bonus against ranged
  | AbMaxHP        -- ^ maximal hp
  | AbMaxCalm      -- ^ maximal calm
  | AbSpeed        -- ^ speed in m/10s (not when pushed or pulled)
  | AbSight        -- ^ FOV radius, where 1 means a single tile FOV
  | AbSmell        -- ^ smell radius
  | AbShine        -- ^ shine radius
  | AbNocto        -- ^ noctovision radius
  | AbAggression   -- ^ aggression, e.g., when closing in for melee
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- | Skill level in particular abilities.
--
-- This representation is sparse, so better than a record when there are more
-- item kinds (with few abilities) than actors (with many abilities),
-- especially if the number of abilities grows as the engine is developed.
-- It's also easier to code and maintain.
type Skills = EM.EnumMap Ability Int

zeroSkills :: Skills
zeroSkills = EM.empty

unitSkills :: Skills
unitSkills = EM.fromDistinctAscList $ zip [AbMove .. AbApply] (repeat 1)

addSkills :: Skills -> Skills -> Skills
addSkills = EM.unionWith (+)

scaleSkills :: Int -> Skills -> Skills
scaleSkills n = EM.map (n *)

tacticSkills :: Tactic -> Skills
tacticSkills TExplore = zeroSkills
tacticSkills TFollow = zeroSkills
tacticSkills TFollowNoItems = ignoreItems
tacticSkills TMeleeAndRanged = meleeAndRanged
tacticSkills TMeleeAdjacent = meleeAdjacent
tacticSkills TBlock = blockOnly
tacticSkills TRoam = zeroSkills
tacticSkills TPatrol = zeroSkills

minusTen, blockOnly, meleeAdjacent, meleeAndRanged, ignoreItems :: Skills

-- To make sure only a lot of weak items can override move-only-leader, etc.
minusTen = EM.fromDistinctAscList $ zip [AbMove .. AbApply] (repeat (-10))

blockOnly = EM.delete AbWait minusTen

meleeAdjacent = EM.delete AbMelee blockOnly

-- Melee and reaction fire.
meleeAndRanged = EM.delete AbProject meleeAdjacent

ignoreItems = EM.fromList $ zip [AbMoveItem, AbProject, AbApply] (repeat (-10))

instance NFData Ability

instance Binary Ability where
  put = putWord8 . toEnum . fromEnum
  get = fmap (toEnum . fromEnum) getWord8

instance Hashable Ability
