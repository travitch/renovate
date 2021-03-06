{-# LANGUAGE FlexibleContexts #-}
-- | Define the strategy for laying out 'SymbolicBlock's
module Renovate.Redirect.LayoutBlocks (
  Layout(..),
  layoutBlocks,
  LayoutStrategy(..),
  Allocator(..),
  TrampolineStrategy(..),
  Grouping(..),
  CompactOrdering(..),
  RewritePair(..)
  ) where

import qualified Data.ByteString as BS
import           Control.Monad.IO.Class ( MonadIO )
import           Data.Map ( Map )
import qualified Data.Traversable as T
import           Data.Typeable ( Typeable )

import           Renovate.Address
import           Renovate.BasicBlock ( InstructionConstraints, AddressAssignedBlock, SymbolicBlock )
import           Renovate.Recovery ( SymbolicCFG )
import           Renovate.Redirect.Monad
import           Renovate.Redirect.LayoutBlocks.Compact ( Layout(..), compactLayout )
import           Renovate.Redirect.LayoutBlocks.Types ( LayoutStrategy(..)
                                                      , Grouping(..)
                                                      , Allocator(..)
                                                      , TrampolineStrategy(..)
                                                      , CompactOrdering(..)
                                                      , RewritePair(..)
                                                      , WithProvenance
                                                      )

-- | Compute a concrete address for each 'SymbolicBlock'.
--
-- Right now, we use an inefficient encoding of jumps.  We could do
-- better later on.
layoutBlocks :: (MonadIO m, T.Traversable t, InstructionConstraints arch, Typeable arch)
             => LayoutStrategy
             -> ConcreteAddress arch
             -- ^ Address to begin block layout of instrumented blocks
             -> t (WithProvenance SymbolicBlock arch)
             -> t (SymbolicAddress arch, BS.ByteString)
             -> Map (ConcreteAddress arch) (SymbolicCFG arch)
             -> RewriterT arch m (Layout AddressAssignedBlock arch)
layoutBlocks strat startAddr blocks injectedCode cfgs =
  compactLayout startAddr strat blocks injectedCode cfgs
