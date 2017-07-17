{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables, TypeSynonymInstances, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving, ViewPatterns, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
module Text.PrettyPrint.Compact.Core(Layout(..),Options(..),Document(..),Doc(..),renderWith) where

import Prelude ()
import Prelude.Compat as P

import Data.List.Compat (sortOn,groupBy)
import Data.Function (on)
import Data.Semigroup
import Data.Sequence (singleton, Seq, viewl, viewr, ViewL(..), ViewR(..), (|>))
import Data.String
import Data.Foldable (toList)
import Data.Maybe (listToMaybe, catMaybes)
-- | Annotated string, which consists of segments with separate (or no) annotations.
--
-- We keep annotated segments in a container (list).
-- The annotation is @Maybe a@, because the no-annotation case is common.
--
-- /Note:/ with @Last x@ annotation, the 'annotate' will overwrite all annotations.
--
-- /Note:/ if the list is changed into `Seq` or similar structure
-- allowing fast viewr and viewl, then we can impose an additional
-- invariant that there aren't two consequtive non-annotated segments;
-- yet there is no performance reason to do so.
--
data AS a = AS !Int [(a, String)]
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

-- | Tests the invariants of 'AS'
_validAs :: AS a -> Bool
_validAs (AS i s) = lengthInvariant && noNewlineInvariant
  where
    lengthInvariant = i == sum (map (length . snd) s)
    noNewlineInvariant = all (notElem '\n' . snd) s

asLength :: AS a -> Int
asLength (AS l _) = l

-- | Make a non-annotated 'AS'.
mkAS :: Monoid a => String -> AS a
mkAS s = AS (length s) [(mempty, s)]

instance Semigroup (AS a) where
  AS i xs <> AS j ys = AS (i + j) (xs <> ys)

newtype L a = L (Seq (AS a)) -- non-empty sequence
  deriving (Eq,Ord,Show,Functor,Foldable,Traversable)

instance Monoid a => Semigroup (L a) where
  L (viewr -> xs :> x) <> L (viewl -> y :< ys) = L (xs <> singleton (x <> y) <> fmap (indent <>) ys)
      where n = asLength x
            indent = mkAS (P.replicate n ' ')
  L _ <> L _ = error "<> @L: invariant violated, Seq is empty"

instance Monoid a => Monoid (L a) where
   mempty = L (singleton (mkAS ""))
   mappend = (<>)

instance Layout L where
  text = L . singleton . mkAS
  flush (L xs) = L (xs |> mkAS "")
  annotate a (L s') = L (fmap annotateAS s') where
    -- annotateAS :: AS a -> AS a
    annotateAS (AS i s) = AS i (fmap annotatePart s)
    annotatePart (b, s) = (b `mappend` a, s)

renderLayout :: (Monoid a, Monoid t) => Options a t -> L a -> t
renderLayout opts (L xs) = intercalate (toList xs)
    where
      f = optsAnnotate opts
      f' (AS _ s) = foldMap (uncurry f) s
      sep = f mempty "\n"

      intercalate []     = mempty
      intercalate (y:ys) = f' y `mappend` foldMap (mappend sep . f') ys

renderWith :: (Monoid r,  Monoid a)
             => Options a r  -- ^ rendering options
             -> Doc a          -- ^ renderable
             -> r
renderWith opts (Doc d) = renderLayout opts $ case interpPDoc d False pageWidth of
      [] -> case interpNarrow d False of
        Nothing -> error "No suitable layout found."
        Just (_ :-: x) -> x
      ((_ :-:x):_) -> x
    where
      pageWidth = optsPageWidth opts

data Options a r = Options
    { optsPageWidth :: !Int              -- ^ maximum page width
    , optsAnnotate  :: a -> String -> r  -- ^ how to annotate the string. /Note:/ the annotation should preserve the visible length of the string.
    }


class Layout d where
  text :: Monoid a => String -> d a
  flush :: Monoid a => d a -> d a
  -- | `<>` a new annotation to the 'Doc'.
  --
  -- Example: 'Any True' annotation will transform the rendered 'Doc' into uppercase:
  --
  -- >>> let r = putStrLn . renderWith defaultOptions { optsAnnotate = \a x -> if a == Any True then map toUpper x else x }
  -- >>> r $ text "hello" <$$> annotate (Any True) (text "world")
  -- hello
  -- WORLD
  annotate :: Monoid a => a -> d a -> d a

class Layout d => Document d where
  (<|>) :: d a -> d a -> d a
  -- | fail if the argument is multi-line
  singleLine :: d a -> d a

-- | type parameter is phantom.
data M a = M {height    :: Int,
              lastWidth :: Int,
              maxWidth  :: Int
              }
  deriving (Show,Eq,Ord,Functor,Foldable,Traversable)

instance Semigroup (M a) where
  a <> b =
    M {maxWidth = max (maxWidth a) (maxWidth b + lastWidth a),
       height = height a + height b,
       lastWidth = lastWidth a + lastWidth b}

instance Monoid a => Monoid (M a) where
  mempty = text ""
  mappend = (<>)

instance Layout M where
  text s = M {height = 0, maxWidth = length s, lastWidth = length s}
  flush a = M {maxWidth = maxWidth a,
               height = height a + 1,
               lastWidth = 0}
  annotate _ M{..} = M{..}

class Poset a where
  (≺) :: a -> a -> Bool


instance Poset (M a) where
  M c1 l1 s1 ≺ M c2 l2 s2 = c1 <= c2 && l1 <= l2 && s1 <= s2

mergeOn :: Ord b => (a -> b) -> [a] -> [a] -> [a]
mergeOn m = go
  where
    go [] xs = xs
    go xs [] = xs
    go (x:xs) (y:ys)
      | m x <= m y  = x:go xs (y:ys)
      | otherwise    = y:go (x:xs) ys

mergeAllOn :: Ord b => (a -> b) -> [[a]] -> [a]
mergeAllOn _ [] = []
mergeAllOn m (x:xs) = mergeOn m x (mergeAllOn m xs)

bestsOn :: forall a b. (Poset b, Ord b)
      => (a -> b) -- ^ measure
      -> [[a]] -> [a]
bestsOn m = paretoOn' m [] . mergeAllOn m

-- | @paretoOn m = paretoOn' m []@
paretoOn' :: Poset b => (a -> b) -> [a] -> [a] -> [a]
paretoOn' _ acc [] = P.reverse acc
paretoOn' m acc (x:xs) = if any ((≺ m x) . m) acc
                            then paretoOn' m acc xs
                            else paretoOn' m (x:acc) xs
                            -- because of the ordering, we have that
                            -- for all y ∈ acc, y <= x, and thus x ≺ y
                            -- is false. No need to refilter acc.

-- list sorted by lexicographic order for the first component
-- function argument is the page width
newtype PDoc a = MkDoc {interpPDoc :: Bool {- single line only -} -> Int -> [Pair M L a]}

instance Monoid a => Semigroup (PDoc a) where
  MkDoc xs <> MkDoc ys = MkDoc $ \s w -> bestsOn frst [ discardInvalid w [x <> y | y <- ys s w] | x <- xs s w]
    where discardInvalid w = filter (fits w . frst)

instance Monoid a => Monoid (PDoc a) where
  mempty = text ""
  mappend = (<>)

fits :: Int -> M a -> Bool
fits w x = maxWidth x <= w

instance Layout PDoc where
  flush (MkDoc xs) = MkDoc $ \s w -> if s
    then []
    else bestsOn frst $ map (sortOn frst) $ groupBy ((==) `on` (height . frst)) $ (map flush (xs s w))
  -- flush xs = paretoOn' fst [] $ sort $ (map flush xs)
  text s = MkDoc $ \_ _ -> [text s]
  annotate a (MkDoc xs) = MkDoc $ \s w -> fmap (annotate a) (xs s w)


instance Document PDoc where
  MkDoc m1 <|> MkDoc m2 = MkDoc $ \s w -> bestsOn frst [m1 s w,m2 s w]
  singleLine (MkDoc m) = MkDoc $ \_s w -> (m True w)

newtype NarrowDoc a = NDoc {interpNarrow :: Bool {- single line only -} -> Maybe (Pair M L a)}

instance Monoid a => Semigroup (NarrowDoc a) where
  NDoc x <> NDoc y = NDoc $ \s -> (<>) <$> x s <*> y s

instance Layout NarrowDoc where
  flush (NDoc xs) = NDoc $ \s -> if s
    then Nothing
    else flush <$> xs s
  text s = NDoc $ \_ -> Just (text s)
  annotate a (NDoc xs) = NDoc $ \s -> fmap (annotate a) (xs s)

instance Document NarrowDoc where
  NDoc m1 <|> NDoc m2 = NDoc $ \s -> listToMaybe $ sortOn ((\M{..} -> (lastWidth,maxWidth)) . frst) $ catMaybes [m1 s, m2 s]
  singleLine (NDoc m) = NDoc $ \_s -> (m True)


instance Monoid a => Monoid (NarrowDoc a) where
  mempty = text ""
  mappend = (<>)

data Pair f g a = (:-:) {frst :: f a,  scnd :: g a}

instance (Semigroup (f a), Semigroup (g a)) => Semigroup (Pair f g a) where
  (x :-: y) <> (x' :-: y') = (x <> x') :-: (y <> y')
instance (Monoid (f a), Monoid (g a)) => Monoid (Pair f g a) where
  mempty = mempty :-: mempty
  mappend (x :-: y)(x' :-: y') = (x `mappend` x') :-: (y `mappend` y')

instance (Layout a, Layout b) => Layout (Pair a b) where
  text s = text s :-: text s
  flush (a:-:b) = (flush a:-: flush b)
  annotate x (a:-:b) = (annotate x a:-:annotate x b)

newtype Doc a = Doc (forall d. (Document d,Monoid (d a)) => d a)

instance Monoid a => Monoid (Doc a) where
  mempty = text ""
  mappend = (<>)

instance Monoid a => Semigroup (Doc a) where
  Doc x <> Doc y = Doc (mappend x y)

instance Layout Doc where
  text s = Doc (text s)
  flush (Doc xs) = Doc (flush xs)
  annotate a (Doc xs) = Doc (annotate a xs)

instance Document Doc where
  Doc m1 <|> Doc m2 = Doc (m1 <|> m2)
  singleLine (Doc m) = Doc (singleLine m)

instance Monoid a => IsString (Doc a) where
  fromString = text

-- $setup
-- >>> import Text.PrettyPrint.Compact
-- >>> import Data.Monoid
-- >>> import Data.Char
