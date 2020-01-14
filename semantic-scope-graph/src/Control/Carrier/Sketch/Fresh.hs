{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DerivingVia                #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

module Control.Carrier.Sketch.Fresh
  ( SketchC (..)
  , runSketch
  , module Control.Effect.Sketch
  ) where

import           Control.Algebra
import           Control.Carrier.Fresh.Strict
import           Control.Carrier.State.Strict
import           Control.Effect.Sketch
import           Control.Monad.IO.Class
import           Data.Module
import           Data.Name (Name)
import qualified Data.Name
import           Data.Bifunctor
import           Data.ScopeGraph (ScopeGraph)
import qualified Data.ScopeGraph as ScopeGraph
import           Data.Semilattice.Lower
import qualified System.Path as Path
import Source.Span

newtype Sketchbook address = Sketchbook
  { sGraph  :: ScopeGraph address
  } deriving (Eq, Show, Lower)

newtype SketchC address m a = SketchC (StateC (Sketchbook address) (FreshC m) a)
  deriving (Applicative, Functor, Monad, MonadIO)

instance forall address sig m . (address ~ Name, Effect sig, Algebra sig m) => Algebra (Sketch Name :+: sig) (SketchC Name m) where
  alg (L (Declare n _props k)) = do
    old <- SketchC (gets @(Sketchbook address) sGraph)
    addr <- SketchC Data.Name.gensym
    let (new, _pos) =
          ScopeGraph.declare
          (ScopeGraph.Declaration (Data.Name.name n))
          (lowerBound @ModuleInfo)
          ScopeGraph.Default
          ScopeGraph.Public
          (lowerBound @Span)
          ScopeGraph.Identifier
          Nothing
          addr
          old
    SketchC (put (Sketchbook new))
    k ()
  alg (R other) = SketchC (alg (R (R (handleCoercible other))))

runSketch ::
  (Ord address, Functor m)
  => Maybe Path.AbsRelFile
  -> SketchC address m a
  -> m (ScopeGraph address, a)
runSketch _rootpath (SketchC go)
  = evalFresh 0
  . fmap (first sGraph)
  . runState lowerBound
  $ go

