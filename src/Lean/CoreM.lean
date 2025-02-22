/-
Copyright (c) 2020 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
import Lean.Util.RecDepth
import Lean.Util.Trace
import Lean.Data.Options
import Lean.Environment
import Lean.Exception
import Lean.InternalExceptionId
import Lean.Eval
import Lean.MonadEnv
import Lean.ResolveName

namespace Lean
namespace Core

register_builtin_option maxHeartbeats : Nat := {
  defValue := 200000
  descr := "maximum amount of heartbeats per command. A heartbeat is number of (small) memory allocations (in thousands), 0 means no limit"
}

def getMaxHeartbeats (opts : Options) : Nat :=
  maxHeartbeats.get opts * 1000

abbrev InstantiateLevelCache := Std.PersistentHashMap Name (List Level × Expr)

structure Cache where
  instLevelType  : InstantiateLevelCache := {}
  instLevelValue : InstantiateLevelCache := {}
  deriving Inhabited

/-- State for the CoreM monad. -/
structure State where
  env             : Environment
  nextMacroScope  : MacroScope    := firstFrontendMacroScope + 1
  ngen            : NameGenerator := {}
  traceState      : TraceState    := {}
  cache           : Cache         := {}
  deriving Inhabited

/-- Context for the CoreM monad. -/
structure Context where
  options        : Options := {}
  currRecDepth   : Nat := 0
  maxRecDepth    : Nat := 1000
  ref            : Syntax := Syntax.missing
  currNamespace  : Name := Name.anonymous
  openDecls      : List OpenDecl := []
  initHeartbeats : Nat := 0
  maxHeartbeats  : Nat := getMaxHeartbeats options
  currMacroScope : MacroScope := firstFrontendMacroScope

/-- CoreM is a monad for manipulating the Lean environment.
It is the base monad for `MetaM`.
The main features it provides are:
- name generator state
- environment state
- Lean options context
- the current open namespace
-/
abbrev CoreM := ReaderT Context <| StateRefT State (EIO Exception)

-- Make the compiler generate specialized `pure`/`bind` so we do not have to optimize through the
-- whole monad stack at every use site. May eventually be covered by `deriving`.
instance : Monad CoreM := let i := inferInstanceAs (Monad CoreM); { pure := i.pure, bind := i.bind }

instance : Inhabited (CoreM α) where
  default := fun _ _ => throw default

instance : MonadRef CoreM where
  getRef := return (← read).ref
  withRef ref x := withReader (fun ctx => { ctx with ref := ref }) x

instance : MonadEnv CoreM where
  getEnv := return (← get).env
  modifyEnv f := modify fun s => { s with env := f s.env, cache := {} }

instance : MonadOptions CoreM where
  getOptions := return (← read).options

instance : MonadWithOptions CoreM where
  withOptions f x := withReader (fun ctx => { ctx with options := f ctx.options }) x

instance : AddMessageContext CoreM where
  addMessageContext := addMessageContextPartial

instance : MonadNameGenerator CoreM where
  getNGen := return (← get).ngen
  setNGen ngen := modify fun s => { s with ngen := ngen }

instance : MonadRecDepth CoreM where
  withRecDepth d x := withReader (fun ctx => { ctx with currRecDepth := d }) x
  getRecDepth := return (← read).currRecDepth
  getMaxRecDepth := return (← read).maxRecDepth

instance : MonadResolveName CoreM where
  getCurrNamespace := return (← read).currNamespace
  getOpenDecls := return (← read).openDecls

protected def withFreshMacroScope (x : CoreM α) : CoreM α := do
  let fresh ← modifyGetThe Core.State (fun st => (st.nextMacroScope, { st with nextMacroScope := st.nextMacroScope + 1 }))
  withReader (fun ctx => { ctx with currMacroScope := fresh }) x

instance : MonadQuotation CoreM where
  getCurrMacroScope   := return (← read).currMacroScope
  getMainModule       := return (← get).env.mainModule
  withFreshMacroScope := Core.withFreshMacroScope

@[inline] def modifyCache (f : Cache → Cache) : CoreM Unit :=
  modify fun ⟨env, next, ngen, trace, cache⟩ => ⟨env, next, ngen, trace, f cache⟩

@[inline] def modifyInstLevelTypeCache (f : InstantiateLevelCache → InstantiateLevelCache) : CoreM Unit :=
  modifyCache fun ⟨c₁, c₂⟩ => ⟨f c₁, c₂⟩

@[inline] def modifyInstLevelValueCache (f : InstantiateLevelCache → InstantiateLevelCache) : CoreM Unit :=
  modifyCache fun ⟨c₁, c₂⟩ => ⟨c₁, f c₂⟩

def instantiateTypeLevelParams (c : ConstantInfo) (us : List Level) : CoreM Expr := do
  if let some (us', r) := (← get).cache.instLevelType.find? c.name then
    if us == us' then
      return r
  let r := c.instantiateTypeLevelParams us
  modifyInstLevelTypeCache fun s => s.insert c.name (us, r)
  return r

def instantiateValueLevelParams (c : ConstantInfo) (us : List Level) : CoreM Expr := do
  if let some (us', r) := (← get).cache.instLevelValue.find? c.name then
    if us == us' then
      return r
  let r := c.instantiateValueLevelParams us
  modifyInstLevelValueCache fun s => s.insert c.name (us, r)
  return r

@[inline] def liftIOCore (x : IO α) : CoreM α := do
  let ref ← getRef
  IO.toEIO (fun (err : IO.Error) => Exception.error ref (toString err)) x

instance : MonadLift IO CoreM where
  monadLift := liftIOCore

instance : MonadTrace CoreM where
  getTraceState := return (← get).traceState
  modifyTraceState f := modify fun s => { s with traceState := f s.traceState }

/-- Restore backtrackable parts of the state. -/
def restore (b : State) : CoreM Unit :=
  modify fun s => { s with env := b.env }

private def mkFreshNameImp (n : Name) : CoreM Name := do
  let fresh ← modifyGet fun s => (s.nextMacroScope, { s with nextMacroScope := s.nextMacroScope + 1 })
  return addMacroScope (← getEnv).mainModule n fresh

def mkFreshUserName (n : Name) : CoreM Name :=
  mkFreshNameImp n

@[inline] def CoreM.run (x : CoreM α) (ctx : Context) (s : State) : EIO Exception (α × State) :=
  (x ctx).run s

@[inline] def CoreM.run' (x : CoreM α) (ctx : Context) (s : State) : EIO Exception α :=
  Prod.fst <$> x.run ctx s

@[inline] def CoreM.toIO (x : CoreM α) (ctx : Context) (s : State) : IO (α × State) := do
  match (← (x.run { ctx with initHeartbeats := (← IO.getNumHeartbeats) } s).toIO') with
  | Except.error (Exception.error _ msg)   => throw <| IO.userError (← msg.toString)
  | Except.error (Exception.internal id _) => throw <| IO.userError <| "internal exception #" ++ toString id.idx
  | Except.ok a                            => return a

instance [MetaEval α] : MetaEval (CoreM α) where
  eval env opts x _ := do
    let x : CoreM α := do try x finally printTraces
    let (a, s) ← x.toIO { maxRecDepth := maxRecDepth.get opts, options := opts } { env := env }
    MetaEval.eval s.env opts a (hideUnit := true)

-- withIncRecDepth for a monad `m` such that `[MonadControlT CoreM n]`
protected def withIncRecDepth [Monad m] [MonadControlT CoreM m] (x : m α) : m α :=
  controlAt CoreM fun runInBase => withIncRecDepth (runInBase x)

def throwMaxHeartbeat (moduleName : Name) (optionName : Name) (max : Nat) : CoreM Unit := do
  let msg := s!"(deterministic) timeout at '{moduleName}', maximum number of heartbeats ({max/1000}) has been reached (use 'set_option {optionName} <num>' to set the limit)"
  throw <| Exception.error (← getRef) (MessageData.ofFormat (Std.Format.text msg))

def checkMaxHeartbeatsCore (moduleName : String) (optionName : Name) (max : Nat) : CoreM Unit := do
  unless max == 0 do
    let numHeartbeats ← IO.getNumHeartbeats
    if numHeartbeats - (← read).initHeartbeats > max then
      throwMaxHeartbeat moduleName optionName max

def checkMaxHeartbeats (moduleName : String) : CoreM Unit := do
  checkMaxHeartbeatsCore moduleName `maxHeartbeats (← read).maxHeartbeats

private def withCurrHeartbeatsImp (x : CoreM α) : CoreM α := do
  let heartbeats ← IO.getNumHeartbeats
  withReader (fun ctx => { ctx with initHeartbeats := heartbeats }) x

def withCurrHeartbeats [Monad m] [MonadControlT CoreM m] (x : m α) : m α :=
  controlAt CoreM fun runInBase => withCurrHeartbeatsImp (runInBase x)

end Core

export Core (CoreM mkFreshUserName checkMaxHeartbeats withCurrHeartbeats)

@[inline] def catchInternalId [Monad m] [MonadExcept Exception m] (id : InternalExceptionId) (x : m α) (h : Exception → m α) : m α := do
  try
    x
  catch ex => match ex with
    | Exception.error _ _      => throw ex
    | Exception.internal id' _ => if id == id' then h ex else throw ex

@[inline] def catchInternalIds [Monad m] [MonadExcept Exception m] (ids : List InternalExceptionId) (x : m α) (h : Exception → m α) : m α := do
  try
    x
  catch ex => match ex with
    | Exception.error _ _     => throw ex
    | Exception.internal id _ => if ids.contains id then h ex else throw ex

/--
  Return true if `ex` was generated by `throwMaxHeartbeat`.
  This function is a bit hackish. The heartbeat exception should probably be an internal exception.
  We used a similar hack at `Exception.isMaxRecDepth` -/
def Exception.isMaxHeartbeat (ex : Exception) : Bool :=
  match ex with
  | Exception.error _ (MessageData.ofFormat (Std.Format.text msg)) => "(deterministic) timeout".isPrefixOf msg
  | _ => false

end Lean
