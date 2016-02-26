-- | Re-export the external Futhark modules for convenience.
module Language.Futhark
  ( module Language.Futhark.Syntax
  , module Language.Futhark.Attributes
  , module Language.Futhark.Pretty
  , module Language.Futhark.Traversals

  , Ident, Parameter, Exp, Lambda
  , Pattern, FunDec, Prog
  , Type, DeclType, ArrayType
  )
  where

import Language.Futhark.Syntax
import Language.Futhark.Attributes
import Language.Futhark.Pretty
import Language.Futhark.Traversals

-- | An identifier with type- and aliasing information information.
type Ident = IdentBase (TypeBase Rank Names) VName

-- | A name with a type, but no aliasing information.  Used for
-- denoting function parameters.
type Parameter = IdentBase (TypeBase ShapeDecl NoInfo) VName

-- | An expression with type information.
type Exp = ExpBase (TypeBase Rank Names) VName

-- | A lambda with type information.
type Lambda = LambdaBase (TypeBase Rank Names) VName

-- | A pattern with type information.
type Pattern = PatternBase (TypeBase Rank Names) VName

-- | An function declaration with type information.
type FunDec = FunDecBase (TypeBase Rank Names) VName

-- | An Futhark program with type information.
type Prog = ProgBase (TypeBase Rank Names) VName

-- | A known type with no shape annotations, but aliasing information.
type Type = TypeBase Rank Names VName

-- | A known type with shape annotations but no aliasing information.
type DeclType = TypeBase ShapeDecl NoInfo VName

-- | A known array type with no shape annotations, but aliasing
-- information.
type ArrayType = ArrayTypeBase Rank Names VName
