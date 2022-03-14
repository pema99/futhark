{-# LANGUAGE OverloadedStrings #-}

-- | Multicore imperative code.
module Futhark.CodeGen.ImpCode.Multicore
  ( Program,
    Function,
    FunctionT (Function),
    Code,
    Multicore (..),
    Scheduling (..),
    SchedulerInfo (..),
    AtomicOp (..),
    ParallelTask (..),
    module Futhark.CodeGen.ImpCode,
  )
where

import Futhark.CodeGen.ImpCode hiding (Code, Function)
import qualified Futhark.CodeGen.ImpCode as Imp
import Futhark.Util.Pretty

-- | An imperative program.
type Program = Imp.Functions Multicore

-- | An imperative function.
type Function = Imp.Function Multicore

-- | A piece of imperative code, with multicore operations inside.
type Code = Imp.Code Multicore

-- | A multicore operation.
data Multicore
  = SegOp String [Param] ParallelTask (Maybe ParallelTask) [Param] SchedulerInfo
  | ParLoop String Code [Param]
  | -- | Emit code in ISPC
    ISPCKernel Code [Param] [Param]
  | -- | ForEach, only valid in ISPC
    ForEach VName Exp Code
  | -- | ForEach_Active, only valid in ISPC
    ForEachActive VName Code
  | -- | Escape hatch for generating builtin ISPC functions
    -- like extract or broadcast
    ISPCBuiltin VName Name [Exp]
  | -- | Retrieve inclusive start and exclusive end indexes of the
    -- chunk we are supposed to be executing.  Only valid immediately
    -- inside a 'ParLoop' construct!
    GetLoopBounds VName VName
  | -- | Retrieve the task ID that is currently executing.  Only valid
    -- immediately inside a 'ParLoop' construct!
    GetTaskId VName
  | -- | Retrieve the number of subtasks to execute.  Only valid
    -- immediately inside a 'SegOp' or 'ParLoop' construct!
    GetNumTasks VName
  | Atomic AtomicOp

-- | Atomic operations return the value stored before the update.
-- This old value is stored in the first 'VName'.  The second 'VName'
-- is the memory block to update.  The 'Exp' is the new value.
data AtomicOp
  = AtomicAdd IntType VName VName (Count Elements (Imp.TExp Int32)) Exp
  | AtomicSub IntType VName VName (Count Elements (Imp.TExp Int32)) Exp
  | AtomicAnd IntType VName VName (Count Elements (Imp.TExp Int32)) Exp
  | AtomicOr IntType VName VName (Count Elements (Imp.TExp Int32)) Exp
  | AtomicXor IntType VName VName (Count Elements (Imp.TExp Int32)) Exp
  | AtomicXchg PrimType VName VName (Count Elements (Imp.TExp Int32)) Exp
  | AtomicCmpXchg PrimType VName VName (Count Elements (Imp.TExp Int32)) VName Exp
  deriving (Show)

instance FreeIn AtomicOp where
  freeIn' (AtomicAdd _ _ arr i x) = freeIn' arr <> freeIn' i <> freeIn' x
  freeIn' (AtomicSub _ _ arr i x) = freeIn' arr <> freeIn' i <> freeIn' x
  freeIn' (AtomicAnd _ _ arr i x) = freeIn' arr <> freeIn' i <> freeIn' x
  freeIn' (AtomicOr _ _ arr i x) = freeIn' arr <> freeIn' i <> freeIn' x
  freeIn' (AtomicXor _ _ arr i x) = freeIn' arr <> freeIn' i <> freeIn' x
  freeIn' (AtomicCmpXchg _ _ arr i retval x) = freeIn' arr <> freeIn' i <> freeIn' x <> freeIn' retval
  freeIn' (AtomicXchg _ _ arr i x) = freeIn' arr <> freeIn' i <> freeIn' x

data SchedulerInfo = SchedulerInfo
  { iterations :: Imp.Exp, -- The number of total iterations for a task
    scheduling :: Scheduling -- The type scheduling for the task
  }

newtype ParallelTask = ParallelTask Code

-- | Whether the Scheduler should schedule the tasks as Dynamic
-- or it is restainted to Static
data Scheduling
  = Dynamic
  | Static

instance Pretty Scheduling where
  ppr Dynamic = "Dynamic"
  ppr Static = "Static"

instance Pretty SchedulerInfo where
  ppr (SchedulerInfo i sched) =
    stack
      [ nestedBlock "scheduling {" "}" (ppr sched),
        nestedBlock "iter {" "}" (ppr i)
      ]

instance Pretty ParallelTask where
  ppr (ParallelTask code) = ppr code

instance Pretty Multicore where
  ppr (GetLoopBounds start end) =
    ppr (start, end) <+> "<-" <+> "get_loop_bounds()"
  ppr (GetTaskId v) =
    ppr v <+> "<-" <+> "get_task_id()"
  ppr (GetNumTasks v) =
    ppr v <+> "<-" <+> "get_num_tasks()"
  ppr (SegOp s free seq_code par_code retval scheduler) =
    "SegOp" <+> text s <+> nestedBlock "{" "}" ppbody
    where
      ppbody =
        stack
          [ ppr scheduler,
            nestedBlock "free {" "}" (ppr free),
            nestedBlock "seq {" "}" (ppr seq_code),
            maybe mempty (nestedBlock "par {" "}" . ppr) par_code,
            nestedBlock "retvals {" "}" (ppr retval)
          ]
  ppr (ParLoop s body params) =
    "parloop" <+> ppr s </> nestedBlock "{" "}" ppbody
    where
      ppbody =
        stack
          [ nestedBlock "params {" "}" (ppr params),
            nestedBlock "body {" "}" (ppr body)
          ]
  ppr (Atomic _) =
    "AtomicOp"
  ppr (ISPCKernel body _ _) =
    text "ispc {"
      </> indent 2 (ppr body)
      </> text "}"
  ppr (ForEach i limit body) =
    text "foreach" <+> ppr i <+> langle <+> ppr limit <+> text "{"
      </> indent 2 (ppr body)
      </> text "}"
  ppr (ForEachActive i body) =
    text "foreach_active" <+> ppr i <+> text "{"
    </> indent 2 (ppr body)
    </> text "}" 
  ppr (ISPCBuiltin dest name args) =
    ppr dest <+> "<-" <+> ppr name <+> "(" <+> ppr args <+> ")"

instance FreeIn SchedulerInfo where
  freeIn' (SchedulerInfo iter _) = freeIn' iter

instance FreeIn ParallelTask where
  freeIn' (ParallelTask code) = freeIn' code

instance FreeIn Multicore where
  freeIn' (GetLoopBounds start end) =
    freeIn' (start, end)
  freeIn' (GetTaskId v) =
    freeIn' v
  freeIn' (GetNumTasks v) =
    freeIn' v
  freeIn' (SegOp _ _ par_code seq_code _ info) =
    freeIn' par_code <> freeIn' seq_code <> freeIn' info
  freeIn' (ParLoop _ body _) =
    freeIn' body
  freeIn' (Atomic aop) =
    freeIn' aop
  freeIn' (ISPCKernel body _ _) =
    freeIn' body
  freeIn' (ForEach i bound body) =
    fvBind (oneName i) (freeIn' body <> freeIn' bound)
  freeIn' (ForEachActive i body) =
    fvBind (oneName i) (freeIn' body)
  freeIn' (ISPCBuiltin dest _ args) =
    freeIn' dest <> freeIn' args