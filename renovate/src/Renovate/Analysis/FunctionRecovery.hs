{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
-- | A simple function recovery pass
--
-- This module performs a simple forward reachability pass from the
-- function roots that are discovered by macaw.
--
-- A more sophisticated version will be written eventually, probably
-- built in to macaw.  Note that this version does not handle indirect
-- jumps (including jump tables).  Only blocks reachable from direct
-- jumps will be in the CFG.
module Renovate.Analysis.FunctionRecovery (
  recoverFunctions,
  Completion(..),
  FunctionCFG(..)
  ) where

import qualified GHC.Err.Located as L

import           Control.Applicative
import qualified Control.Monad.RWS.Strict as RWS
import qualified Data.Foldable as F
import qualified Data.List.NonEmpty as DLN
import qualified Data.Map.Strict as M
import           Data.Parameterized.Some ( Some(..) )
import           Data.Semigroup
import qualified Data.Set as S

import qualified Data.Macaw.CFG as MM

import           Prelude

import           Renovate.Address
import           Renovate.BasicBlock
import           Renovate.ISA
import           Renovate.Recovery

-- | Mark a CFG as complete or incomplete
--
-- A complete CFG has all of its basic blocks and all of the
-- connections between them.
--
-- An incomplete CFG is missing some blocks due to e.g., indirect
-- jumps that could not be resolved.
data Completion = Complete
                | Incomplete
                deriving (Eq, Ord, Show)

-- | We assume a function is identified by its entry point, so that
-- e.g. 'Ord' and 'Eq' for 'FunctionCFG' are defined in terms of the
-- entry point.
data FunctionCFG arch = FunctionCFG { cfgEntry :: ConcreteAddress arch
                                   -- ^ The entry point of the function
                                   , cfgSuccessors :: M.Map (ConcreteAddress arch) [ConcreteAddress arch]
                                   -- ^ The successors of each block
                                   , cfgExitBlocks :: [ConcreteAddress arch]
                                   -- ^ Exit blocks of the function
                                   , cfgBlocks :: [ConcreteAddress arch] -- M.Map (ConcreteAddress arch) (ConcreteBlock arch)
                                   -- ^ All of the blocks in the CFG
                                   , cfgCompletion :: Completion
                                   -- ^ Whether or not the CFG is complete
                                   }
deriving instance ( MM.MemWidth (MM.RegAddrWidth (MM.ArchReg arch)) )
  => Show (FunctionCFG arch)

instance Eq (FunctionCFG arch) where
  c1 == c2 = cfgEntry c1 == cfgEntry c2

instance Ord (FunctionCFG arch) where
  c1 `compare` c2 = cfgEntry c1 `compare` cfgEntry c2

-- | Starting from a basic set of recovered block information from
-- macaw, assign basic blocks to functions and construct CFGs.
recoverFunctions :: (MM.MemWidth (MM.ArchAddrWidth arch))
                 => ISA arch
                 -> MM.Memory (MM.ArchAddrWidth arch)
                 -> BlockInfo arch
                 -> [FunctionCFG arch]
recoverFunctions isa mem blockInfo = runM isa mem blockInfo $ do
  F.foldlM buildCFG [] (biFunctionEntries blockInfo)

-- | Given a function entry point, traverse forward across all of its
-- basic blocks that we can find to build up a CFG.
--
-- If we encounter an indirect jump (that isn't a call), mark the CFG
-- as incomplete.
--
-- We do not follow call edges.
buildCFG :: (MM.MemWidth (MM.ArchAddrWidth arch))
         => [FunctionCFG arch]
         -> ConcreteAddress arch
         -> M arch [FunctionCFG arch]
buildCFG acc entryAddr = do
  mcfg <- makeCFGForEntry entryAddr
  case mcfg of
    Just cfg -> return (cfg : acc)
    Nothing -> return acc

{-

Take a worklist approach with a local state monad where we build up
the components of a function CFG.  Examine the last instruction of the
block:

 * If it is a jump, figure out the jump type and add successors to the
   worklist, if we can identify them (if we can't find them, toggle
   hasIndirectJump)

 * If it is a call, add the address of the instruction after the call
   to the worklist

 * If it is not a terminator at all, add the next instruction to the
   worklist

-}

makeCFGForEntry :: (MM.MemWidth (MM.ArchAddrWidth arch)) => ConcreteAddress arch -> M arch (Maybe (FunctionCFG arch))
makeCFGForEntry entryAddr = do
  addBlockToWorklist entryAddr
  processWorklist
  st <- resetState
  return $ Just $ FunctionCFG { cfgEntry = entryAddr
                              , cfgSuccessors = fmap F.toList (fsSuccessors st)
                              , cfgExitBlocks = F.toList (fsExitBlocks st)
                              , cfgBlocks = F.toList (fsVisited st)
                              , cfgCompletion = if fsHasIndirectJump st then Incomplete else Complete
                              }

processWorklist :: forall arch . (MM.MemWidth (MM.ArchAddrWidth arch)) => M arch ()
processWorklist = do
  wl <- RWS.gets fsWorklist
  case S.minView wl of
    Nothing -> return ()
    Just (addr, rest) -> do
      RWS.modify' $ \s -> s { fsVisited = S.insert addr (fsVisited s)
                            , fsWorklist = rest
                            }
      b <- M.lookup addr <$> RWS.asks envBlocks >>= \case
        Just b -> return b
        Nothing -> L.error $ "Address " <> show addr <> " not found in blocks"
      isa <- RWS.asks envISA
      mem <- RWS.asks envMem
      withInstructionAddresses isa b $ \_repr insns -> do
        let (lastInsn, insnAddr) = DLN.last insns
            addSuccessor :: M arch ()
            addSuccessor = nextBlockAddress b >>= addCFGEdge addr
            addCond :: JumpCondition -> M arch ()
            addCond Unconditional = return ()
            addCond Conditional = addSuccessor
        Some pb <- return (concreteDiscoveryBlock b)
        () <- case isaJumpType isa lastInsn mem insnAddr pb of
          -- Fallthrough to the next block
          Some NoJump -> addSuccessor
          Some (Return cond) -> do
            addReturnBlock addr
            addCond cond
          Some (RelativeJump cond jaddr off) -> do
            let target = jaddr `addressAddOffset` off
            addCFGEdge addr target
            addCond cond
          Some (AbsoluteJump cond dst) -> do
            addCFGEdge addr dst
            addCond cond
          Some (IndirectJump cond) -> do
            addCond cond
            markFunctionIncomplete
          Some (DirectCall {}) -> addSuccessor
          Some IndirectCall -> addSuccessor
          Some (NotInstrumentable {}) -> markFunctionIncomplete
        processWorklist

nextBlockAddress :: (MM.MemWidth (MM.ArchAddrWidth arch)) => ConcreteBlock arch -> M arch (ConcreteAddress arch)
nextBlockAddress b = do
  isa <- RWS.asks envISA
  let sz     = blockSize isa b
  return (concreteBlockAddress b `addressAddOffset` fromIntegral sz)

markFunctionIncomplete :: M arch ()
markFunctionIncomplete = do
  RWS.modify' $ \s -> s { fsHasIndirectJump = True }

addReturnBlock :: ConcreteAddress arch -> M arch ()
addReturnBlock addr =
  RWS.modify' $ \s -> s { fsExitBlocks = S.insert addr (fsExitBlocks s) }

{-# INLINE addCFGEdge #-}
addCFGEdge :: ConcreteAddress arch -> ConcreteAddress arch -> M arch ()
addCFGEdge src dst = do
  RWS.modify' $ \s -> s { fsSuccessors = M.insertWith S.union src (S.singleton dst) (fsSuccessors s) }
  addBlockToWorklist dst

{-# INLINE addBlockToWorklist #-}
addBlockToWorklist :: ConcreteAddress arch -> M arch ()
addBlockToWorklist addr = do
  RWS.modify' $ \s ->
    case S.member addr (fsVisited s) of
      True -> s
      False -> s { fsWorklist = S.insert addr (fsWorklist s) }

newtype M arch t = M { unM :: RWS.RWS (CFGEnv arch) () (FunctionState arch) t }
  deriving (Monad,
            Applicative,
            Functor,
            RWS.MonadReader (CFGEnv arch),
            RWS.MonadState (FunctionState arch))

data CFGEnv arch = CFGEnv { envBlocks :: M.Map (ConcreteAddress arch) (ConcreteBlock arch)
                          , envISA :: ISA arch
                          , envMem :: MM.Memory (MM.ArchAddrWidth arch)
                          }

data FunctionState arch =
  FunctionState { fsSuccessors :: M.Map (ConcreteAddress arch) (S.Set (ConcreteAddress arch))
                , fsExitBlocks :: S.Set (ConcreteAddress arch)
                , fsHasIndirectJump :: Bool
                , fsVisited :: S.Set (ConcreteAddress arch)
                , fsWorklist :: S.Set (ConcreteAddress arch)
                }

emptyFunctionState :: FunctionState arch
emptyFunctionState = FunctionState { fsSuccessors = M.empty
                                   , fsExitBlocks = S.empty
                                   , fsHasIndirectJump = False
                                   , fsVisited = S.empty
                                   , fsWorklist = S.empty
                                   }

-- | Reset the function state, returning the old state
resetState :: M arch (FunctionState arch)
resetState = do
  s <- RWS.get
  RWS.put emptyFunctionState
  return s

runM :: ISA arch -> MM.Memory (MM.ArchAddrWidth arch) -> BlockInfo arch -> M arch t -> t
runM isa mem blockInfo act = fst $ RWS.evalRWS (unM act) env emptyFunctionState
  where
    env = CFGEnv { envBlocks = F.foldl' addBlock M.empty (biBlocks blockInfo)
                 , envISA = isa
                 , envMem = mem
                 }
    addBlock m b = M.insert (concreteBlockAddress b) b m
