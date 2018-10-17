{-# LANGUAGE DeriveAnyClass, GADTs, KindSignatures, Rank2Types #-}
module Control.Abstract.Value
( AbstractValue(..)
, AbstractIntro(..)
, Comparator(..)
-- * Value effects
-- $valueEffects
, function
, BuiltIn(..)
, builtIn
, call
, Function(..)
, boolean
, asBool
, ifthenelse
, disjunction
, Boolean(..)
, while
, doWhile
, forLoop
, While(..)
, makeNamespace
, evaluateInScopedEnv
, address
, value
, rvalBox
) where

import Control.Abstract.Environment
import Control.Abstract.Evaluator
import Control.Abstract.Heap
import Data.Abstract.BaseError
import Data.Abstract.Environment as Env
import Data.Abstract.Module
import Data.Abstract.Name
import Data.Abstract.Number as Number
import Data.Abstract.Ref
import Data.Scientific (Scientific)
import Data.Span
import Prologue hiding (TypeError, catchError)

-- | This datum is passed into liftComparison to handle the fact that Ruby and PHP
--   have built-in generalized-comparison ("spaceship") operators. If you want to
--   encapsulate a traditional, boolean-returning operator, wrap it in 'Concrete';
--   if you want the generalized comparator, pass in 'Generalized'. In 'AbstractValue'
--   instances, you can then then handle the different cases to return different
--   types, if that's what you need.
data Comparator
  = Concrete (forall a . Ord a => a -> a -> Bool)
  | Generalized

-- Value effects

-- $valueEffects
-- Value effects are effects modelling the /introduction/ & /elimination/ of some specific kind of value.
--
-- Modelling each of these as effects has several advantages∷
--
-- * It is strictly more flexible than modelling them as methods in a typeclass, as effect list–indexed typeclasses must be constrained at every list of effects at which they can be applied, whereas effect membership constraints can be deduced recursively (i.e. if @X@ is constrained to be a member of @effects@, it is automatically deducible that it is also a member of @Y \': effects@).
-- * It offers us the potential of specializing the handlers on a language-by-language basis without the need for extra type parameters (albeit at the cost of automatic selection).
-- * It offers us the potential of fine-grained specialization of the abstract domain, enabling convenient, piecemeal customization of the domain, and even semi-abstract domains.
-- * Finally, it should eventually allow us to customize _which_ value effects are available for a given language; e.g. a language without OO features would not require OO value effects. (This would also rely on 'Evaluatable' instances being able to specify membership constraints, which is not currently possible.)
--
-- In the concrete domain, introductions & eliminations respectively construct & pattern match against values, while in abstract domains they respectively construct & project finite sets of discrete observations of abstract values. For example, an abstract domain modelling integers as a sign (-, 0, or +) would introduce abstract values by mapping integers to their sign and eliminate them by mapping signs back to some canonical integer, e.g. - -> -1, 0 -> 0, + -> 1.

function :: Member (Function term address value) effects => Maybe Name -> [Name] -> term -> Evaluator term address value effects value
function name params body = sendFunction (Function name params body)

data BuiltIn
  = Print
  | Show
  deriving (Eq, Ord, Show, Generic, NFData)

builtIn :: Member (Function term address value) effects => BuiltIn -> Evaluator term address value effects value
builtIn = sendFunction . BuiltIn

call :: Member (Function term address value) effects => value -> address -> [address] -> Evaluator term address value effects address
call fn self args = sendFunction (Call fn self args)

sendFunction :: Member (Function term address value) effects => Function term address value (Eff effects) a -> Evaluator term address value effects a
sendFunction = send

data Function term address value (m :: * -> *) result where
  Function :: Maybe Name -> [Name] -> term -> Function term address value m value
  BuiltIn  :: BuiltIn -> Function term address value m value
  Call     :: value -> address -> [address] -> Function term address value m address

instance PureEffect (Function term address value)
instance Effect (Function term address value) where
  handleState state handler (Request (Function name params body) k) = Request (Function name params body) (handler . (<$ state) . k)
  handleState state handler (Request (BuiltIn builtIn)           k) = Request (BuiltIn builtIn)           (handler . (<$ state) . k)
  handleState state handler (Request (Call fn self addrs)        k) = Request (Call fn self addrs)        (handler . (<$ state) . k)

-- | Construct a boolean value in the abstract domain.
boolean :: Member (Boolean value) effects => Bool -> Evaluator term address value effects value
boolean = send . Boolean

-- | Extract a 'Bool' from a given value.
asBool :: Member (Boolean value) effects => value -> Evaluator term address value effects Bool
asBool = send . AsBool

-- | Eliminate boolean values. TODO: s/boolean/truthy
ifthenelse :: Member (Boolean value) effects => value -> Evaluator term address value effects a -> Evaluator term address value effects a -> Evaluator term address value effects a
ifthenelse v t e = asBool v >>= \ c -> if c then t else e

-- | Compute the disjunction (boolean or) of two computed values. This should have short-circuiting semantics where applicable.
disjunction :: Member (Boolean value) effects => Evaluator term address value effects value -> Evaluator term address value effects value -> Evaluator term address value effects value
disjunction (Evaluator a) (Evaluator b) = send (Disjunction a b)

data Boolean value m result where
  Boolean     :: Bool  -> Boolean value m value
  AsBool      :: value -> Boolean value m Bool
  Disjunction :: m value -> m value -> Boolean value m value

instance PureEffect (Boolean value) where
  handle handler (Request (Boolean b)        k) = Request (Boolean b) (handler . k)
  handle handler (Request (AsBool v)         k) = Request (AsBool v)  (handler . k)
  handle handler (Request (Disjunction a b)  k) = Request (Disjunction (handler a) (handler b))  (handler . k)

-- | The fundamental looping primitive, built on top of 'ifthenelse'.
while :: Member (While value) effects
  => Evaluator term address value effects value -- ^ Condition
  -> Evaluator term address value effects value -- ^ Body
  -> Evaluator term address value effects value
while (Evaluator cond) (Evaluator body) = send (While cond body)

-- | Do-while loop, built on top of while.
doWhile :: Member (While value) effects
  => Evaluator term address value effects value -- ^ Body
  -> Evaluator term address value effects value -- ^ Condition
  -> Evaluator term address value effects value
doWhile body cond = body *> while cond body

-- | C-style for loops.
forLoop :: (Member (While value) effects, Member (Env address) effects)
  => Evaluator term address value effects value -- ^ Initial statement
  -> Evaluator term address value effects value -- ^ Condition
  -> Evaluator term address value effects value -- ^ Increment/stepper
  -> Evaluator term address value effects value -- ^ Body
  -> Evaluator term address value effects value
forLoop initial cond step body =
  locally (initial *> while cond (body *> step))

data While value m result where
  While :: m value -> m value -> While value m value

instance PureEffect (While value) where
  handle handler (Request (While cond body) k) = Request (While (handler cond) (handler body)) (handler . k)


class Show value => AbstractIntro value where
  -- | Construct an abstract unit value.
  --   TODO: This might be the same as the empty tuple for some value types
  unit :: value

  -- | Construct an abstract string value.
  string :: Text -> value

  -- | Construct a self-evaluating symbol value.
  --   TODO: Should these be interned in some table to provide stronger uniqueness guarantees?
  symbol :: Text -> value

  -- | Construct an abstract regex value.
  regex :: Text -> value

  -- | Construct an abstract integral value.
  integer :: Integer -> value

  -- | Construct a floating-point value.
  float :: Scientific -> value

  -- | Construct a rational value.
  rational :: Rational -> value

  -- | Construct a key-value pair for use in a hash.
  kvPair :: value -> value -> value

  -- | Construct a hash out of pairs.
  hash :: [(value, value)] -> value

  -- | Construct the nil/null datatype.
  null :: value

-- | A 'Monad' abstracting the evaluation of (and under) binding constructs (functions, methods, etc).
--
--   This allows us to abstract the choice of whether to evaluate under binders for different value types.
class AbstractIntro value => AbstractValue term address value effects where
  -- | Cast numbers to integers
  castToInteger :: value -> Evaluator term address value effects value


  -- | Lift a unary operator over a 'Num' to a function on 'value's.
  liftNumeric  :: (forall a . Num a => a -> a)
               -> (value -> Evaluator term address value effects value)

  -- | Lift a pair of binary operators to a function on 'value's.
  --   You usually pass the same operator as both arguments, except in the cases where
  --   Haskell provides different functions for integral and fractional operations, such
  --   as division, exponentiation, and modulus.
  liftNumeric2 :: (forall a b. Number a -> Number b -> SomeNumber)
               -> (value -> value -> Evaluator term address value effects value)

  -- | Lift a Comparator (usually wrapping a function like == or <=) to a function on values.
  liftComparison :: Comparator -> (value -> value -> Evaluator term address value effects value)

  -- | Lift a unary bitwise operator to values. This is usually 'complement'.
  liftBitwise :: (forall a . Bits a => a -> a)
              -> (value -> Evaluator term address value effects value)

  -- | Lift a binary bitwise operator to values. The Integral constraint is
  --   necessary to satisfy implementation details of Haskell left/right shift,
  --   but it's fine, since these are only ever operating on integral values.
  liftBitwise2 :: (forall a . (Integral a, Bits a) => a -> a -> a)
               -> (value -> value -> Evaluator term address value effects value)

  unsignedRShift :: value -> value -> Evaluator term address value effects value

  -- | Construct an N-ary tuple of multiple (possibly-disjoint) values
  tuple :: [address] -> Evaluator term address value effects value

  -- | Construct an array of zero or more values.
  array :: [address] -> Evaluator term address value effects value

  asArray :: value -> Evaluator term address value effects [address]

  -- | Extract the contents of a key-value pair as a tuple.
  asPair :: value -> Evaluator term address value effects (value, value)

  -- | Extract a 'Text' from a given value.
  asString :: value -> Evaluator term address value effects Text

  -- | @index x i@ computes @x[i]@, with zero-indexing.
  index :: value -> value -> Evaluator term address value effects address

  -- | Build a class value from a name and environment.
  klass :: Name             -- ^ The new class's identifier
        -> [address]        -- ^ A list of superclasses
        -> Bindings address -- ^ The environment to capture
        -> Evaluator term address value effects value

  -- | Build a namespace value from a name and environment stack
  --
  -- Namespaces model closures with monoidal environments.
  namespace :: Name                 -- ^ The namespace's identifier
            -> Maybe address        -- The ancestor of the namespace
            -> Bindings address     -- ^ The environment to mappend
            -> Evaluator term address value effects value

  -- | Extract the environment from any scoped object (e.g. classes, namespaces, etc).
  scopedEnvironment :: address -> Evaluator term address value effects (Maybe (Environment address))


makeNamespace :: ( AbstractValue term address value effects
                 , Member (Deref value) effects
                 , Member (Env address) effects
                 , Member (State (Heap address value)) effects
                 , Ord address
                 )
              => Name
              -> address
              -> Maybe address
              -> Evaluator term address value effects ()
              -> Evaluator term address value effects value
makeNamespace name addr super body = do
  namespaceBinds <- Env.head <$> locally (body >> getEnv)
  v <- namespace name super namespaceBinds
  v <$ assign addr v


-- | Evaluate a term within the context of the scoped environment of 'scopedEnvTerm'.
evaluateInScopedEnv :: ( AbstractValue term address value effects
                       , Member (Env address) effects
                       )
                    => address
                    -> Evaluator term address value effects a
                    -> Evaluator term address value effects a
evaluateInScopedEnv receiver term = do
  scopedEnv <- scopedEnvironment receiver
  env <- maybeM getEnv scopedEnv
  withEvalContext (EvalContext (Just receiver) env) term


-- | Evaluates a 'Value' returning the referenced value
value :: ( AbstractValue term address value effects
         , Member (Deref value) effects
         , Member (Env address) effects
         , Member (Reader ModuleInfo) effects
         , Member (Reader Span) effects
         , Member (Resumable (BaseError (AddressError address value))) effects
         , Member (Resumable (BaseError (EnvironmentError address))) effects
         , Member (State (Heap address value)) effects
         , Ord address
         )
      => ValueRef address
      -> Evaluator term address value effects value
value = deref <=< address

-- | Returns the address of a value referenced by a 'ValueRef'
address :: ( AbstractValue term address value effects
           , Member (Env address) effects
           , Member (Reader ModuleInfo) effects
           , Member (Reader Span) effects
           , Member (Resumable (BaseError (EnvironmentError address))) effects
           )
        => ValueRef address
        -> Evaluator term address value effects address
address (LvalLocal var)       = variable var
address (LvalMember ptr prop) = evaluateInScopedEnv ptr (variable prop)
address (Rval addr)           = pure addr

-- | Convenience function for boxing a raw value and wrapping it in an Rval
rvalBox :: ( Member (Allocator address) effects
           , Member (Deref value) effects
           , Member Fresh effects
           , Member (State (Heap address value)) effects
           , Ord address
           )
        => value
        -> Evaluator term address value effects (ValueRef address)
rvalBox val = Rval <$> box val
