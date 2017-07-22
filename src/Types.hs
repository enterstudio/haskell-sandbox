module Types where

import qualified Data.HashSet           as S
import qualified Data.Text              as T
import qualified Data.Vector            as V

import           Control.Monad.Reader

import Data.Hashable (Hashable(..))

type Identifier = T.Text
type Query = T.Text
type Row = V.Vector Identifier

data Relation = Relation {
  headers  :: V.Vector Identifier,
  elements :: S.HashSet Row
} deriving (Eq, Show)

data Expression =
  Project (V.Vector Identifier) Expression |
  RelationFromEnv Identifier
  deriving (Eq, Show)

type Env = Relation

type Eval a = Reader Env a

instance (Hashable a) => Hashable (V.Vector a) where
  hashWithSalt salt = hashWithSalt salt . V.toList
  {-# INLINE hashWithSalt #-}