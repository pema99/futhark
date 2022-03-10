{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | C code generator.  This module can convert a correct ImpCode
-- program to an equivalent C program.
module Futhark.CodeGen.Backends.MulticoreC
  ( compileProg,
    generateContext,
    GC.CParts (..),
    GC.asLibrary,
    GC.asExecutable,
    GC.asISPCExecutable,
    GC.asServer,
    operations,
    cliOptions,
  )
where

import Control.Monad
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Text as T
import Futhark.CodeGen.Backends.GenericC.Options
import Futhark.CodeGen.Backends.SimpleRep
import Futhark.CodeGen.ImpCode.Multicore
import qualified Futhark.CodeGen.ImpGen.Multicore as ImpGen
import Futhark.CodeGen.RTS.C (schedulerH)
import Futhark.IR.MCMem (MCMem, Prog)
import Futhark.MonadFreshNames
import qualified Language.C.Quote.ISPC as C
import qualified Language.C.Syntax as C
import qualified Futhark.CodeGen.Backends.GenericC as GC

-- | Compile the program to ImpCode with multicore operations.
compileProg ::
  MonadFreshNames m => T.Text -> T.Text -> Prog MCMem -> m (ImpGen.Warnings, GC.CParts)
compileProg header version =
  traverse
    ( GC.compileProg
        "multicore"
        version
        operations
        generateContext
        header
        [DefaultSpace]
        cliOptions
    )
    <=< ImpGen.compileProg

generateContext :: GC.CompilerM op () ()
generateContext = do
  mapM_ GC.earlyDecl [C.cunit|$esc:(T.unpack schedulerH)|]

  cfg <- GC.publicDef "context_config" GC.InitDecl $ \s ->
    ( [C.cedecl|struct $id:s;|],
      [C.cedecl|struct $id:s { int in_use;
                               int debugging;
                               int profiling;
                               int num_threads;
                             };|]
    )

  GC.publicDef_ "context_config_new" GC.InitDecl $ \s ->
    ( [C.cedecl|struct $id:cfg* $id:s(void);|],
      [C.cedecl|struct $id:cfg* $id:s(void) {
                             struct $id:cfg *cfg = (struct $id:cfg*) malloc(sizeof(struct $id:cfg));
                             if (cfg == NULL) {
                               return NULL;
                             }
                             cfg->in_use = 0;
                             cfg->debugging = 0;
                             cfg->profiling = 0;
                             cfg->num_threads = 0;
                             return cfg;
                           }|]
    )

  GC.publicDef_ "context_config_free" GC.InitDecl $ \s ->
    ( [C.cedecl|void $id:s(struct $id:cfg* cfg);|],
      [C.cedecl|void $id:s(struct $id:cfg* cfg) {
                             assert(!cfg->in_use);
                             free(cfg);
                           }|]
    )

  GC.publicDef_ "context_config_set_debugging" GC.InitDecl $ \s ->
    ( [C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
      [C.cedecl|void $id:s(struct $id:cfg* cfg, int detail) {
                      cfg->debugging = detail;
                    }|]
    )

  GC.publicDef_ "context_config_set_profiling" GC.InitDecl $ \s ->
    ( [C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
      [C.cedecl|void $id:s(struct $id:cfg* cfg, int flag) {
                      cfg->profiling = flag;
                    }|]
    )

  GC.publicDef_ "context_config_set_logging" GC.InitDecl $ \s ->
    ( [C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
      [C.cedecl|void $id:s(struct $id:cfg* cfg, int detail) {
                             // Does nothing for this backend.
                             (void)cfg; (void)detail;
                           }|]
    )

  GC.publicDef_ "context_config_set_num_threads" GC.InitDecl $ \s ->
    ( [C.cedecl|void $id:s(struct $id:cfg *cfg, int n);|],
      [C.cedecl|void $id:s(struct $id:cfg *cfg, int n) {
                             cfg->num_threads = n;
                           }|]
    )

  (fields, init_fields, free_fields) <- GC.contextContents

  ctx <- GC.publicDef "context" GC.InitDecl $ \s ->
    ( [C.cedecl|struct $id:s;|],
      [C.cedecl|struct $id:s {
                      struct $id:cfg* cfg;
                      struct scheduler scheduler;
                      int detail_memory;
                      int debugging;
                      int profiling;
                      int profiling_paused;
                      int logging;
                      typename lock_t lock;
                      char *error;
                      typename FILE *log;
                      int total_runs;
                      long int total_runtime;
                      $sdecls:fields

                      // Tuning parameters
                      typename int64_t tuning_timing;
                      typename int64_t tuning_iter;
                    };|]
    )

  GC.publicDef_ "context_new" GC.InitDecl $ \s ->
    ( [C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg);|],
      [C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg) {
             assert(!cfg->in_use);
             struct $id:ctx* ctx = (struct $id:ctx*) malloc(sizeof(struct $id:ctx));
             if (ctx == NULL) {
               return NULL;
             }
             ctx->cfg = cfg;
             ctx->cfg->in_use = 1;

             // Initialize rand()
             fast_srand(time(0));
             ctx->detail_memory = cfg->debugging;
             ctx->debugging = cfg->debugging;
             ctx->profiling = cfg->profiling;
             ctx->profiling_paused = 0;
             ctx->logging = 0;
             ctx->error = NULL;
             ctx->log = stderr;
             create_lock(&ctx->lock);

             int tune_kappa = 0;
             double kappa = 5.1f * 1000;

             if (tune_kappa) {
               if (determine_kappa(&kappa) != 0) {
                 return NULL;
               }
             }

             if (scheduler_init(&ctx->scheduler,
                                cfg->num_threads > 0 ?
                                cfg->num_threads : num_processors(),
                                kappa) != 0) {
               return NULL;
             }

             $stms:init_fields

             init_constants(ctx);

             return ctx;
          }|]
    )

  GC.publicDef_ "context_free" GC.InitDecl $ \s ->
    ( [C.cedecl|void $id:s(struct $id:ctx* ctx);|],
      [C.cedecl|void $id:s(struct $id:ctx* ctx) {
             $stms:free_fields
             free_constants(ctx);
             (void)scheduler_destroy(&ctx->scheduler);
             free_lock(&ctx->lock);
             ctx->cfg->in_use = 0;
             free(ctx);
           }|]
    )

  GC.publicDef_ "context_sync" GC.InitDecl $ \s ->
    ( [C.cedecl|int $id:s(struct $id:ctx* ctx);|],
      [C.cedecl|int $id:s(struct $id:ctx* ctx) {
                             (void)ctx;
                             return 0;
                           }|]
    )

  GC.earlyDecl [C.cedecl|static const char *tuning_param_names[0];|]
  GC.earlyDecl [C.cedecl|static const char *tuning_param_vars[0];|]
  GC.earlyDecl [C.cedecl|static const char *tuning_param_classes[0];|]

  GC.publicDef_ "context_config_set_tuning_param" GC.InitDecl $ \s ->
    ( [C.cedecl|int $id:s(struct $id:cfg* cfg, const char *param_name, typename size_t param_value);|],
      [C.cedecl|int $id:s(struct $id:cfg* cfg, const char *param_name, typename size_t param_value) {
                     (void)cfg; (void)param_name; (void)param_value;
                     return 1;
                   }|]
    )

cliOptions :: [Option]
cliOptions =
  [ Option
      { optionLongName = "profile",
        optionShortName = Just 'P',
        optionArgument = NoArgument,
        optionAction = [C.cstm|futhark_context_config_set_profiling(cfg, 1);|],
        optionDescription = "Gather profiling information."
      },
    Option
      { optionLongName = "num-threads",
        optionShortName = Nothing,
        optionArgument = RequiredArgument "INT",
        optionAction = [C.cstm|futhark_context_config_set_num_threads(cfg, atoi(optarg));|],
        optionDescription = "Set number of threads used for execution."
      }
  ]

operations :: GC.Operations Multicore ()
operations =
  GC.defaultOperations
    { GC.opsCompiler = compileOp,
      GC.opsCritical =
        -- The thread entering an API function is always considered
        -- the "first worker" - note that this might differ from the
        -- thread that created the context!  This likely only matters
        -- for entry points, since they are the only API functions
        -- that contain parallel operations.
        ( [C.citems|worker_local = &ctx->scheduler.workers[0];|],
          []
        )
    }

closureFreeStructField :: VName -> Name
closureFreeStructField v =
  nameFromString "free_" <> nameFromString (pretty v)

closureRetvalStructField :: VName -> Name
closureRetvalStructField v =
  nameFromString "retval_" <> nameFromString (pretty v)

getName :: VName -> Name
getName name = nameFromString $ pretty name

isMemblock :: Param -> Bool
isMemblock (MemParam _ _) = True
isMemblock _  = False

data ValueType = Prim | MemBlock | RawMem

-- Escaped memory name to immediately deref within function scope.
freshMemName :: Param -> Param
freshMemName (MemParam v s) = MemParam (VName (nameFromString ('_' : baseString v)) (baseTag v)) s
freshMemName param = param

-- Compile parameter definitions to pass to ISPC kernel
compileKernelParams :: [VName] -> [(C.Type, ValueType)] -> [C.Param]
compileKernelParams = zipWith field
  where
    field name (ty, Prim) =
      [C.cparam|uniform $ty:ty $id:(getName name)|]
    field name (_, RawMem) =
      [C.cparam|unsigned char uniform * uniform $id:(getName name)|]
    field name (_, _) =
      [C.cparam|uniform typename memblock * uniform $id:(getName name)|]

-- Compile parameter values to ISPC kernel
compileKernelInputs :: [VName] -> [(C.Type, ValueType)] -> [C.Exp]
compileKernelInputs = zipWith field
  where
    field name (_, Prim) = [C.cexp|$id:(getName name)|]
    field name (_, RawMem) = [C.cexp|$id:(getName name)|]
    field name (_, MemBlock) = [C.cexp|&$id:(getName name)|]

-- Immediately dereference a memblock passed to the kernel, so we can use it normally
compileMemblockDeref :: [(VName, VName)] -> [(C.Type, ValueType)] -> [C.InitGroup]
compileMemblockDeref = zipWith deref
  where
    deref (v1, v2) (ty, Prim) = [C.cdecl|$ty:ty $id:v1 = $id:(getName v2);|]
    deref (v1, v2) (_, RawMem) = [C.cdecl|unsigned char uniform * uniform $id:v1 = $id:(getName v2);|]
    deref (v1, v2) (ty, MemBlock) = [C.cdecl|uniform $ty:ty $id:v1 = *$id:(getName v2);|]

compileFreeStructFields :: [VName] -> [(C.Type, ValueType)] -> [C.FieldGroup]
compileFreeStructFields = zipWith field
  where
    field name (ty, Prim) =
      [C.csdecl|$ty:ty $id:(closureFreeStructField name);|]
    field name (_, _) =
      [C.csdecl|$ty:defaultMemBlockType $id:(closureFreeStructField name);|]

compileRetvalStructFields :: [VName] -> [(C.Type, ValueType)] -> [C.FieldGroup]
compileRetvalStructFields = zipWith field
  where
    field name (ty, Prim) =
      [C.csdecl|$ty:ty *$id:(closureRetvalStructField name);|]
    field name (_, _) =
      [C.csdecl|$ty:defaultMemBlockType $id:(closureRetvalStructField name);|]

compileSetStructValues ::
  C.ToIdent a =>
  a ->
  [VName] ->
  [(C.Type, ValueType)] ->
  [C.Stm]
compileSetStructValues struct = zipWith field
  where
    field name (_, Prim) =
      [C.cstm|$id:struct.$id:(closureFreeStructField name)=$id:name;|]
    field name (_, MemBlock) =
      [C.cstm|$id:struct.$id:(closureFreeStructField name)=$id:name.mem;|]
    field name (_, RawMem) =
      [C.cstm|$id:struct.$id:(closureFreeStructField name)=$id:name;|]

compileSetRetvalStructValues ::
  C.ToIdent a =>
  a ->
  [VName] ->
  [(C.Type, ValueType)] ->
  [C.Stm]
compileSetRetvalStructValues struct = zipWith field
  where
    field name (_, Prim) =
      [C.cstm|$id:struct.$id:(closureRetvalStructField name)=&$id:name;|]
    field name (_, MemBlock) =
      [C.cstm|$id:struct.$id:(closureRetvalStructField name)=$id:name.mem;|]
    field name (_, RawMem) =
      [C.cstm|$id:struct.$id:(closureRetvalStructField name)=$id:name;|]

compileGetRetvalStructVals :: C.ToIdent a => a -> [VName] -> [(C.Type, ValueType)] -> [C.InitGroup]
compileGetRetvalStructVals struct = zipWith field
  where
    field name (ty, Prim) =
      [C.cdecl|$ty:ty $id:name = *$id:struct->$id:(closureRetvalStructField name);|]
    field name (ty, _) =
      [C.cdecl|$ty:ty $id:name =
                 {.desc = $string:(pretty name),
                 .mem = $id:struct->$id:(closureRetvalStructField name),
                 .size = 0, .references = NULL};|]

compileGetStructVals ::
  C.ToIdent a =>
  a ->
  [VName] ->
  [(C.Type, ValueType)] ->
  [C.InitGroup]
compileGetStructVals struct = zipWith field
  where
    field name (ty, Prim) =
      [C.cdecl|$ty:ty $id:name = $id:struct->$id:(closureFreeStructField name);|]
    field name (ty, _) =
      [C.cdecl|$ty:ty $id:name =
                 {.desc = $string:(pretty name),
                  .mem = $id:struct->$id:(closureFreeStructField name),
                  .size = 0, .references = NULL};|]

compileWriteBackResVals :: C.ToIdent a => a -> [VName] -> [(C.Type, ValueType)] -> [C.Stm]
compileWriteBackResVals struct = zipWith field
  where
    field name (_, Prim) =
      [C.cstm|*$id:struct->$id:(closureRetvalStructField name) = $id:name;|]
    field name (_, _) =
      [C.cstm|$id:struct->$id:(closureRetvalStructField name) = $id:name.mem;|]

paramToCType :: Param -> GC.CompilerM op s (C.Type, ValueType)
paramToCType (ScalarParam _ pt) = do
  let t = GC.primTypeToCType pt
  return (t, Prim)
paramToCType (MemParam name space') = mcMemToCType name space'

mcMemToCType :: VName -> Space -> GC.CompilerM op s (C.Type, ValueType)
mcMemToCType v space = do
  refcount <- GC.fatMemory space
  cached <- isJust <$> GC.cacheMem v
  return
    ( GC.fatMemType space,
      if refcount && not cached
        then MemBlock
        else RawMem
    )

functionRuntime :: Name -> C.Id
functionRuntime = (`C.toIdent` mempty) . (<> "_total_runtime")

functionRuns :: Name -> C.Id
functionRuns = (`C.toIdent` mempty) . (<> "_runs")

functionIter :: Name -> C.Id
functionIter = (`C.toIdent` mempty) . (<> "_iter")

multiCoreReport :: [(Name, Bool)] -> [C.BlockItem]
multiCoreReport names = report_kernels
  where
    report_kernels = concatMap reportKernel names
    max_name_len_pad = 40
    format_string name True =
      let name_s = nameToString name
          padding = replicate (max_name_len_pad - length name_s) ' '
       in unwords ["tid %2d -", name_s ++ padding, "ran %10d times; avg: %10ldus; total: %10ldus; time pr. iter %9.6f; iters %9ld; avg %ld\n"]
    format_string name False =
      let name_s = nameToString name
          padding = replicate (max_name_len_pad - length name_s) ' '
       in unwords ["        ", name_s ++ padding, "ran %10d times; avg: %10ldus; total: %10ldus; time pr. iter %9.6f; iters %9ld; avg %ld\n"]
    reportKernel (name, is_array) =
      let runs = functionRuns name
          total_runtime = functionRuntime name
          iters = functionIter name
       in if is_array
            then
              [ [C.citem|
                     for (int i = 0; i < ctx->scheduler.num_threads; i++) {
                       fprintf(ctx->log,
                         $string:(format_string name is_array),
                         i,
                         ctx->$id:runs[i],
                         (long int) ctx->$id:total_runtime[i] / (ctx->$id:runs[i] != 0 ? ctx->$id:runs[i] : 1),
                         (long int) ctx->$id:total_runtime[i],
                         (double) ctx->$id:total_runtime[i] /  (ctx->$id:iters[i] == 0 ? 1 : (double)ctx->$id:iters[i]),
                         (long int) (ctx->$id:iters[i]),
                         (long int) (ctx->$id:iters[i]) / (ctx->$id:runs[i] != 0 ? ctx->$id:runs[i] : 1)
                         );
                     }
                   |]
              ]
            else
              [ [C.citem|
                    fprintf(ctx->log,
                       $string:(format_string name is_array),
                       ctx->$id:runs,
                       (long int) ctx->$id:total_runtime / (ctx->$id:runs != 0 ? ctx->$id:runs : 1),
                       (long int) ctx->$id:total_runtime,
                       (double) ctx->$id:total_runtime /  (ctx->$id:iters == 0 ? 1 : (double)ctx->$id:iters),
                       (long int) (ctx->$id:iters),
                       (long int) (ctx->$id:iters) / (ctx->$id:runs != 0 ? ctx->$id:runs : 1));
                   |],
                [C.citem|ctx->total_runtime += ctx->$id:total_runtime;|],
                [C.citem|ctx->total_runs += ctx->$id:runs;|]
              ]

addBenchmarkFields :: Name -> Maybe C.Id -> GC.CompilerM op s ()
addBenchmarkFields name (Just _) = do
  GC.contextFieldDyn
    (functionRuntime name)
    [C.cty|typename int64_t*|]
    [C.cexp|calloc(sizeof(typename int64_t), ctx->scheduler.num_threads)|]
    [C.cstm|free(ctx->$id:(functionRuntime name));|]
  GC.contextFieldDyn
    (functionRuns name)
    [C.cty|int*|]
    [C.cexp|calloc(sizeof(int), ctx->scheduler.num_threads)|]
    [C.cstm|free(ctx->$id:(functionRuns name));|]
  GC.contextFieldDyn
    (functionIter name)
    [C.cty|typename int64_t*|]
    [C.cexp|calloc(sizeof(sizeof(typename int64_t)), ctx->scheduler.num_threads)|]
    [C.cstm|free(ctx->$id:(functionIter name));|]
addBenchmarkFields name Nothing = do
  GC.contextField (functionRuntime name) [C.cty|typename int64_t|] $ Just [C.cexp|0|]
  GC.contextField (functionRuns name) [C.cty|int|] $ Just [C.cexp|0|]
  GC.contextField (functionIter name) [C.cty|typename int64_t|] $ Just [C.cexp|0|]

benchmarkCode :: Name -> Maybe C.Id -> [C.BlockItem] -> GC.CompilerM op s [C.BlockItem]
benchmarkCode name tid code = do
  addBenchmarkFields name tid
  return
    [C.citems|
     typename uint64_t $id:start = 0;
     if (ctx->profiling && !ctx->profiling_paused) {
       $id:start = get_wall_time();
     }
     $items:code
     if (ctx->profiling && !ctx->profiling_paused) {
       typename uint64_t $id:end = get_wall_time();
       typename uint64_t elapsed = $id:end - $id:start;
       $items:(updateFields tid)
     }
     |]
  where
    start = name <> "_start"
    end = name <> "_end"
    updateFields Nothing =
      [C.citems|__atomic_fetch_add(&ctx->$id:(functionRuns name), 1, __ATOMIC_RELAXED);
                                            __atomic_fetch_add(&ctx->$id:(functionRuntime name), elapsed, __ATOMIC_RELAXED);
                                            __atomic_fetch_add(&ctx->$id:(functionIter name), iterations, __ATOMIC_RELAXED);|]
    updateFields (Just _tid') =
      [C.citems|ctx->$id:(functionRuns name)[tid]++;
                                            ctx->$id:(functionRuntime name)[tid] += elapsed;
                                            ctx->$id:(functionIter name)[tid] += iterations;|]

functionTiming :: Name -> C.Id
functionTiming = (`C.toIdent` mempty) . (<> "_total_time")

functionIterations :: Name -> C.Id
functionIterations = (`C.toIdent` mempty) . (<> "_total_iter")

addTimingFields :: Name -> GC.CompilerM op s ()
addTimingFields name = do
  GC.contextField (functionTiming name) [C.cty|typename int64_t|] $ Just [C.cexp|0|]
  GC.contextField (functionIterations name) [C.cty|typename int64_t|] $ Just [C.cexp|0|]

multicoreName :: String -> GC.CompilerM op s Name
multicoreName s = do
  s' <- newVName ("futhark_mc_" ++ s)
  return $ nameFromString $ baseString s' ++ "_" ++ show (baseTag s')

multicoreDef :: String -> (Name -> GC.CompilerM op s C.Definition) -> GC.CompilerM op s Name
multicoreDef s f = do
  s' <- multicoreName s
  GC.libDecl =<< f s'
  return s'

ispcDef :: String -> (Name -> GC.CompilerM op s C.Definition) -> GC.CompilerM op s Name
ispcDef s f = do
  s' <- multicoreName s
  GC.ispcDecl =<< f s'
  return s'

sharedDef :: String -> (Name -> GC.CompilerM op s C.Definition) -> GC.CompilerM op s Name
sharedDef s f = do
  s' <- multicoreName s
  GC.libDecl [C.cedecl|$esc:("#ifndef __ISPC_STRUCT_" <> (nameToString s') <> "__")|]
  GC.libDecl [C.cedecl|$esc:("#define __ISPC_STRUCT_" <> (nameToString s') <> "__")|] -- TODO:(K) - refacor this shit
  GC.libDecl =<< f s'
  GC.libDecl [C.cedecl|$esc:("#endif")|]
  GC.ispcDecl =<< f s'
  return s'

generateParLoopFn ::
  C.ToIdent a =>
  M.Map VName Space ->
  String ->
  Code ->
  a ->
  [(VName, (C.Type, ValueType))] ->
  [(VName, (C.Type, ValueType))] ->
  GC.CompilerM Multicore s Name
generateParLoopFn lexical basename code fstruct free retval = do
  let (fargs, fctypes) = unzip free
  let (retval_args, retval_ctypes) = unzip retval
  multicoreDef basename $ \s -> do
    fbody <- benchmarkCode s (Just "tid") <=< GC.inNewFunction $
      GC.cachingMemory lexical $ \decl_cached free_cached -> GC.collect $ do
        mapM_ GC.item [C.citems|$decls:(compileGetStructVals fstruct fargs fctypes)|]
        mapM_ GC.item [C.citems|$decls:(compileGetRetvalStructVals fstruct retval_args retval_ctypes)|]
        code' <- GC.collect $ GC.compileCode code
        mapM_ GC.item decl_cached
        mapM_ GC.item =<< GC.declAllocatedMem
        mapM_ GC.item code'
        free_mem <- GC.freeAllocatedMem
        GC.stm [C.cstm|cleanup: {$stms:free_cached $items:free_mem}|]
    return
      [C.cedecl|int $id:s(void *args, typename int64_t iterations, int tid, struct scheduler_info info) {
                           int err = 0;
                           int subtask_id = tid;
                           struct $id:fstruct *$id:fstruct = (struct $id:fstruct*) args;
                           struct futhark_context *ctx = $id:fstruct->ctx;
                           $items:fbody
                           if (err == 0) {
                             $stms:(compileWriteBackResVals fstruct retval_args retval_ctypes)
                           }
                           return err;
                      }|]

prepareTaskStruct ::
  String ->
  [VName] ->
  [(C.Type, ValueType)] ->
  [VName] ->
  [(C.Type, ValueType)] ->
  GC.CompilerM Multicore s Name
prepareTaskStruct name free_args free_ctypes retval_args retval_ctypes = do
  let makeStruct s = return
        [C.cedecl|struct $id:s {
                       struct futhark_context *ctx;
                       $sdecls:(compileFreeStructFields free_args free_ctypes)
                       $sdecls:(compileRetvalStructFields retval_args retval_ctypes)
                     };|]
  fstruct <- sharedDef name makeStruct
  let fstruct' =  fstruct <> "_"
  -- TODO(pema, K): These underscores are pretty gross. We need them because of ISPC restriction on struct names.
  GC.decl [C.cdecl|struct $id:fstruct $id:fstruct';|]
  GC.stm [C.cstm|$id:fstruct'.ctx = ctx;|]
  GC.stms [C.cstms|$stms:(compileSetStructValues fstruct' free_args free_ctypes)|]
  GC.stms [C.cstms|$stms:(compileSetRetvalStructValues fstruct' retval_args retval_ctypes)|]
  return fstruct

-- Generate a segop function for top_level and potentially nested SegOp code
compileOp :: GC.OpCompiler Multicore ()
compileOp (GetLoopBounds start end) = do
  GC.stm [C.cstm|$id:start = start;|]
  GC.stm [C.cstm|$id:end = end;|]
compileOp (GetTaskId v) =
  GC.stm [C.cstm|$id:v = subtask_id;|]
compileOp (GetNumTasks v) =
  GC.stm [C.cstm|$id:v = info.nsubtasks;|]
compileOp (SegOp name params seq_task par_task retvals (SchedulerInfo e sched)) = do
  let (ParallelTask seq_code) = seq_task
  free_ctypes <- mapM paramToCType params
  retval_ctypes <- mapM paramToCType retvals
  let free_args = map paramName params
      retval_args = map paramName retvals
      free = zip free_args free_ctypes
      retval = zip retval_args retval_ctypes

  e' <- GC.compileExp e

  let lexical = lexicalMemoryUsage $ Function Nothing [] params seq_code [] []

  fstruct <-
    prepareTaskStruct "task" free_args free_ctypes retval_args retval_ctypes

  fpar_task <- generateParLoopFn lexical (name ++ "_task") seq_code fstruct free retval
  addTimingFields fpar_task

  let ftask_name = fstruct <> "_task"
  
  toC <- GC.collect $ do
    GC.decl [C.cdecl|struct scheduler_segop $id:ftask_name;|]
    GC.stm [C.cstm|$id:ftask_name.args = args;|]
    GC.stm [C.cstm|$id:ftask_name.top_level_fn = $id:fpar_task;|]
    GC.stm [C.cstm|$id:ftask_name.name = $string:(nameToString fpar_task);|]
    GC.stm [C.cstm|$id:ftask_name.iterations = iterations;|]
    -- Create the timing fields for the task
    GC.stm [C.cstm|$id:ftask_name.task_time = &ctx->$id:(functionTiming fpar_task);|]
    GC.stm [C.cstm|$id:ftask_name.task_iter = &ctx->$id:(functionIterations fpar_task);|]

    case sched of
        Dynamic -> GC.stm [C.cstm|$id:ftask_name.sched = DYNAMIC;|]
        Static -> GC.stm [C.cstm|$id:ftask_name.sched = STATIC;|]

    -- Generate the nested segop function if available
    fnpar_task <- case par_task of
        Just (ParallelTask nested_code) -> do
            let lexical_nested = lexicalMemoryUsage $ Function Nothing [] params nested_code [] []
            fnpar_task <- generateParLoopFn lexical_nested (name ++ "_nested_task") nested_code fstruct free retval
            GC.stm [C.cstm|$id:ftask_name.nested_fn = $id:fnpar_task;|]
            return $ zip [fnpar_task] [True]
        Nothing -> do
            GC.stm [C.cstm|$id:ftask_name.nested_fn=NULL;|]
            return mempty

    GC.stm [C.cstm|return scheduler_prepare_task(&ctx->scheduler, &$id:ftask_name);|]

    -- Add profile fields for -P option
    mapM_ GC.profileReport $ multiCoreReport $ (fpar_task, True) : fnpar_task

  schedn <- multicoreDef "schedule_shim" $ \s ->
    return [C.cedecl|int $id:s(struct futhark_context* ctx, void* args, typename int64_t iterations) {
        $items:toC
    }|]

  free_all_mem <- GC.freeAllocatedMem -- TODO(pema): Should this free be here?

  _ <- ispcDef "" $ \_ -> return [C.cedecl| extern "C" unmasked uniform int $id:schedn 
                                                (struct futhark_context uniform * uniform ctx, 
                                                struct $id:fstruct uniform * uniform args, 
                                                uniform int iterations);|]
  GC.stm [C.cstm|$escstm:("#if ISPC")|]
  GC.items [C.citems|
    #if ISPC
    uniform struct $id:fstruct aos[programCount];
    aos[programIndex] = $id:(fstruct <> "_");
    foreach_active (i) {
      if (err == 0) {
        err = $id:schedn(ctx, &aos[i], extract($exp:e', i));
      }
    }|]
  -- TODO(pema): We can't do much else here^^ than set the error code and hope for the best
  GC.stm [C.cstm|$escstm:("#else")|]
  GC.items [C.citems|
    err = $id:schedn(ctx, &$id:(fstruct <> "_"), $exp:e');
    if (err != 0) {
      $items:free_all_mem
      goto cleanup;
    }|]
  GC.stm [C.cstm|$escstm:("#endif")|]

compileOp (ISPCKernel body free retvals) = do
  free_ctypes <- mapM paramToCType free
  let free_args = map paramName free

  -- rename memblocks so we can pass them as pointers, compile the parameters
  let free_names_esc = map freshMemName free
  let free_args_esc = map paramName free_names_esc
  let inputs = compileKernelParams free_args_esc free_ctypes

  -- dereference memblock pointers into the unescaped names
  let mem_args = map paramName $ filter isMemblock free
  let mem_args_esc = map paramName $ filter isMemblock free_names_esc
  mem_ctypes <- mapM paramToCType (filter isMemblock free)
  let memderef = compileMemblockDeref (zip mem_args mem_args_esc) mem_ctypes

  -- TODO(pema): We generate code for a new function without calling GC.inNewFunction,
  -- I think this is a hack. If I understand correctly, it can result in double-frees
  -- when an inner scope thinks that it owns memory from an outer scope.
  let lexical = lexicalMemoryUsage $ Function Nothing [] free body [] []
  -- Generate ISPC kernel
  ispcShim <- ispcDef "loop_ispc" $ \s -> do
    mainBody <- GC.cachingMemory lexical $ \decl_cached free_cached ->
      GC.collect $ do
        GC.decl [C.cdecl|uniform int err = 0;|]
        mapM_ GC.item decl_cached
        mapM_ GC.item =<< GC.declAllocatedMem
        free_mem <- GC.freeAllocatedMem

        GC.compileCode body
        
        GC.stm [C.cstm|cleanup: {$stms:free_cached $items:free_mem}|]
        GC.stm [C.cstm|return err;|]
    --mainBody <- GC.collect $ GC.compileCode body
    return
      [C.cedecl|
        export static uniform int $id:s(struct futhark_context uniform * uniform ctx,
                                 uniform typename int64_t start,
                                 uniform typename int64_t end,
                                 $params:inputs) {
          $decls:memderef
          $items:mainBody
        }|]

  -- Generate C code to call into ISPC kernel
  let ispc_inputs = compileKernelInputs free_args free_ctypes
  free_all_mem <- GC.freeAllocatedMem -- TODO(pema): Should this be here?
  GC.items [C.citems|
    err = $id:ispcShim(ctx, start, end, $args:ispc_inputs);
    if (err != 0) {
      $items:free_all_mem
      goto cleanup;
    }|]

compileOp (ForEach i bound body) = do
  bound' <- GC.compileExp bound
  body' <- GC.collect $ GC.compileCode body
  GC.stm [C.cstm|
    foreach ($id:i = 0 ... extract($exp:bound', 0)) {
      $items:body'
    }|]

compileOp (ForEachActive name body) = do
  body' <- GC.collect $ GC.compileCode body
  GC.stm [C.cstm|
    foreach_active ($id:name) {
      $items:body'
    }|]

compileOp (ParLoop s' body free) = do
  free_ctypes <- mapM paramToCType free
  let free_args = map paramName free

  let lexical = lexicalMemoryUsage $ Function Nothing [] free body [] []

  fstruct <-
    prepareTaskStruct (s' ++ "_parloop_struct") free_args free_ctypes mempty mempty

  ftask <- multicoreDef (s' ++ "_parloop") $ \s -> do
    fbody <- benchmarkCode s (Just "tid") <=< GC.inNewFunction $
      GC.cachingMemory lexical $ \decl_cached free_cached -> GC.collect $ do
        mapM_
          GC.item
          [C.citems|$decls:(compileGetStructVals fstruct free_args free_ctypes)|]

        GC.decl [C.cdecl|typename int64_t iterations = end-start;|]

        body' <- GC.collect $ GC.compileCode body

        mapM_ GC.item decl_cached
        mapM_ GC.item =<< GC.declAllocatedMem
        free_mem <- GC.freeAllocatedMem
        mapM_ GC.item body'
        GC.stm [C.cstm|cleanup: {$stms:free_cached $items:free_mem}|]
    return
      [C.cedecl|static int $id:s(void *args, typename int64_t start, typename int64_t end, int subtask_id, int tid) {
                       int err = 0;
                       struct $id:fstruct *$id:fstruct = (struct $id:fstruct*) args;
                       struct futhark_context *ctx = $id:fstruct->ctx;
                       $items:fbody
                       return err;
                     }|]

  let ftask_name = ftask <> "_task"
  GC.decl [C.cdecl|struct scheduler_parloop $id:ftask_name;|]
  GC.stm [C.cstm|$id:ftask_name.name = $string:(nameToString ftask);|]
  GC.stm [C.cstm|$id:ftask_name.fn = $id:ftask;|]
  GC.stm [C.cstm|$id:ftask_name.args = &$id:(fstruct <> "_");|]
  GC.stm [C.cstm|$id:ftask_name.iterations = iterations;|]
  GC.stm [C.cstm|$id:ftask_name.info = info;|]

  let ftask_err = ftask <> "_err"
      ftask_total = ftask <> "_total"
  code' <-
    benchmarkCode
      ftask_total
      Nothing
      [C.citems|int $id:ftask_err = scheduler_execute_task(&ctx->scheduler,
                                                           &$id:ftask_name);
               if ($id:ftask_err != 0) {
                 err = $id:ftask_err;
                 goto cleanup;
               }|]

  mapM_ GC.item code'
  mapM_ GC.profileReport $ multiCoreReport $ zip [ftask, ftask_total] [True, False]
compileOp (Atomic aop) =
  atomicOps aop

doAtomic ::
  (C.ToIdent a1) =>
  a1 ->
  VName ->
  Count u (TExp Int32) ->
  Exp ->
  String ->
  C.Type ->
  GC.CompilerM op s ()
doAtomic old arr ind val op ty = do
  ind' <- GC.compileExp $ untyped $ unCount ind
  val' <- GC.compileExp val
  arr' <- GC.rawMem arr
  GC.stm [C.cstm|$id:old = $id:op(&(($ty:ty*)$exp:arr')[$exp:ind'], ($ty:ty) $exp:val', __ATOMIC_RELAXED);|]

atomicOps :: AtomicOp -> GC.CompilerM op s ()
atomicOps (AtomicCmpXchg t old arr ind res val) = do
  ind' <- GC.compileExp $ untyped $ unCount ind
  new_val' <- GC.compileExp val
  let cast = [C.cty|$ty:(GC.primTypeToCType t)*|]
  arr' <- GC.rawMem arr
  GC.stm
    [C.cstm|$id:res = $id:op(&(($ty:cast)$exp:arr')[$exp:ind'],
                ($ty:cast)&$id:old,
                 $exp:new_val',
                 0, __ATOMIC_SEQ_CST, __ATOMIC_RELAXED);|]
  where
    op :: String
    op = "__atomic_compare_exchange_n"
atomicOps (AtomicXchg t old arr ind val) = do
  ind' <- GC.compileExp $ untyped $ unCount ind
  val' <- GC.compileExp val
  let cast = [C.cty|$ty:(GC.primTypeToCType t)*|]
  GC.stm [C.cstm|$id:old = $id:op(&(($ty:cast)$id:arr.mem)[$exp:ind'], $exp:val', __ATOMIC_SEQ_CST);|]
  where
    op :: String
    op = "__atomic_exchange_n"
atomicOps (AtomicAdd t old arr ind val) =
  doAtomic old arr ind val "__atomic_fetch_add" [C.cty|$ty:(GC.intTypeToCType t)|]
atomicOps (AtomicSub t old arr ind val) =
  doAtomic old arr ind val "__atomic_fetch_sub" [C.cty|$ty:(GC.intTypeToCType t)|]
atomicOps (AtomicAnd t old arr ind val) =
  doAtomic old arr ind val "__atomic_fetch_and" [C.cty|$ty:(GC.intTypeToCType t)|]
atomicOps (AtomicOr t old arr ind val) =
  doAtomic old arr ind val "__atomic_fetch_or" [C.cty|$ty:(GC.intTypeToCType t)|]
atomicOps (AtomicXor t old arr ind val) =
  doAtomic old arr ind val "__atomic_fetch_xor" [C.cty|$ty:(GC.intTypeToCType t)|]
