%
% (c) The AQUA Project, Glasgow University, 1994-1996
%
\section[PrelArr]{Module @PrelArr@}

Array implementation, @PrelArr@ exports the basic array
types and operations.

For byte-arrays see @PrelByteArr@.

\begin{code}
{-# OPTIONS -fno-implicit-prelude #-}

module PrelArr where

import {-# SOURCE #-} PrelErr ( error )
import Ix
import PrelList (foldl)
import PrelST
import PrelBase
import PrelAddr
import PrelGHC
import PrelShow

infixl 9  !, //

default ()
\end{code}

\begin{code}
{-# SPECIALISE array :: (Int,Int) -> [(Int,b)] -> Array Int b #-}
array		      :: (Ix a) => (a,a) -> [(a,b)] -> Array a b

{-# SPECIALISE (!) :: Array Int b -> Int -> b #-}
(!)		      :: (Ix a) => Array a b -> a -> b

{-# SPECIALISE (//) :: Array Int b -> [(Int,b)] -> Array Int b #-}
(//)		      :: (Ix a) => Array a b -> [(a,b)] -> Array a b

{-# SPECIALISE accum  :: (b -> c -> b) -> Array Int b -> [(Int,c)] -> Array Int b #-}
accum		      :: (Ix a) => (b -> c -> b) -> Array a b -> [(a,c)] -> Array a b

{-# SPECIALISE accumArray :: (b -> c -> b) -> b -> (Int,Int) -> [(Int,c)] -> Array Int b #-}
accumArray	      :: (Ix a) => (b -> c -> b) -> b -> (a,a) -> [(a,c)] -> Array a b

bounds		      :: (Ix a) => Array a b -> (a,a)
assocs		      :: (Ix a) => Array a b -> [(a,b)]
indices		      :: (Ix a) => Array a b -> [a]
\end{code}


%*********************************************************
%*							*
\subsection{The @Array@ types}
%*							*
%*********************************************************

\begin{code}
type IPr = (Int, Int)

data Ix ix => Array ix elt		= Array     	   ix ix (Array# elt)
data Ix ix => MutableArray     s ix elt = MutableArray     ix ix (MutableArray# s elt)


data MutableVar s a = MutableVar (MutVar# s a)

instance Eq (MutableVar s a) where
	MutableVar v1# == MutableVar v2#
		= sameMutVar# v1# v2#

-- just pointer equality on arrays:
instance Eq (MutableArray s ix elt) where
	MutableArray _ _ arr1# == MutableArray _ _ arr2# 
		= sameMutableArray# arr1# arr2#
\end{code}

%*********************************************************
%*							*
\subsection{Operations on mutable variables}
%*							*
%*********************************************************

\begin{code}
newVar   :: a -> ST s (MutableVar s a)
readVar  :: MutableVar s a -> ST s a
writeVar :: MutableVar s a -> a -> ST s ()

newVar init = ST $ \ s# ->
    case (newMutVar# init s#)     of { (# s2#, var# #) ->
    (# s2#, MutableVar var# #) }

readVar (MutableVar var#) = ST $ \ s# -> readMutVar# var# s#

writeVar (MutableVar var#) val = ST $ \ s# ->
    case writeMutVar# var# val s# of { s2# ->
    (# s2#, () #) }
\end{code}

%*********************************************************
%*							*
\subsection{Operations on immutable arrays}
%*							*
%*********************************************************

"array", "!" and "bounds" are basic; the rest can be defined in terms of them

\begin{code}
{-# INLINE bounds #-}
bounds (Array l u _)  = (l,u)

{-# INLINE assocs #-}	-- Want to fuse the list comprehension
assocs a              =  [(i, a!i) | i <- indices a]

{-# INLINE indices #-}
indices		      =  range . bounds

{-# SPECIALISE amap :: (b -> c) -> Array Int b -> Array Int c #-}
amap		      :: (Ix a) => (b -> c) -> Array a b -> Array a c
amap f a              =  array b [(i, f (a!i)) | i <- range b]
                         where b = bounds a

(Array l u arr#) ! i
  = let n# = case (index (l,u) i) of { I# x -> x } -- index fails if out of range
    in
    case (indexArray# arr# n#) of
      (# v #) -> v

{-# INLINE array #-}
array ixs ivs 
  = case rangeSize ixs				of { I# n ->
    runST ( ST $ \ s1 -> 
	case newArray# n arrEleBottom s1	of { (# s2, marr #) ->
	foldr (fill ixs marr) (done ixs marr) ivs s2
    })}

fill :: Ix ix => (ix,ix)  -> MutableArray# s elt
	      -> (ix,elt) -> STRep s a -> STRep s a
{-# INLINE fill #-}
fill ixs marr (i,v) next = \s1 -> case index ixs i	of { I# n ->
				  case writeArray# marr n v s1	of { s2 ->
				  next s2 }}

done :: Ix ix => (ix,ix) -> MutableArray# s elt
	      -> STRep s (Array ix elt)
{-# INLINE done #-}
done (l,u) marr = \s1 -> 
   case unsafeFreezeArray# marr s1 of { (# s2, arr #) ->
   (# s2, Array l u arr #) }

arrEleBottom :: a
arrEleBottom = error "(Array.!): undefined array element"


-----------------------------------------------------------------------
-- These also go better with magic: (//), accum, accumArray
-- *** NB *** We INLINE them all so that their foldr's get to the call site

{-# INLINE (//) #-}
old_array // ivs
  = runST (do
	-- copy the old array:
	arr <- thawArray old_array
	-- now write the new elements into the new array:
	fill_it_in arr ivs
	freezeArray arr
    )

fill_it_in :: Ix ix => MutableArray s ix elt -> [(ix, elt)] -> ST s ()
{-# INLINE fill_it_in #-}
fill_it_in arr lst = foldr (fill_one_in arr) (return ()) lst
	 -- **** STRICT **** (but that's OK...)

fill_one_in arr (i, v) rst = writeArray arr i v >> rst

zap_with_f :: Ix ix => (elt -> elt2 -> elt) -> MutableArray s ix elt -> [(ix,elt2)] -> ST s ()
-- zap_with_f: reads an elem out first, then uses "f" on that and the new value
{-# INLINE zap_with_f #-}

zap_with_f f arr lst
  = foldr (zap_one f arr) (return ()) lst

zap_one f arr (i, new_v) rst = do
        old_v <- readArray arr i
	writeArray arr i (f old_v new_v)
	rst

{-# INLINE accum #-}
accum f old_array ivs
  = runST (do
	-- copy the old array:
	arr <- thawArray old_array
	-- now zap the elements in question with "f":
	zap_with_f f arr ivs
	freezeArray arr
    )

{-# INLINE accumArray #-}
accumArray f zero ixs ivs
  = runST (do
	arr <- newArray ixs zero
	zap_with_f f arr ivs
	freezeArray arr
    )
\end{code}


%*********************************************************
%*							*
\subsection{Array instances}
%*							*
%*********************************************************


\begin{code}
instance Ix a => Functor (Array a) where
  fmap = amap

instance  (Ix a, Eq b)  => Eq (Array a b)  where
    a == a'  	        =  assocs a == assocs a'
    a /= a'  	        =  assocs a /= assocs a'

instance  (Ix a, Ord b) => Ord (Array a b)  where
    compare a b = compare (assocs a) (assocs b)

instance  (Ix a, Show a, Show b) => Show (Array a b)  where
    showsPrec p a = showParen (p > 9) (
		    showString "array " .
		    shows (bounds a) . showChar ' ' .
		    shows (assocs a)                  )
    showList = showList__ (showsPrec 0)

{-
instance  (Ix a, Read a, Read b) => Read (Array a b)  where
    readsPrec p = readParen (p > 9)
	   (\r -> [(array b as, u) | ("array",s) <- lex r,
				     (b,t)       <- reads s,
				     (as,u)      <- reads t   ])
    readList = readList__ (readsPrec 0)
-}
\end{code}


%*********************************************************
%*							*
\subsection{Operations on mutable arrays}
%*							*
%*********************************************************

Idle ADR question: What's the tradeoff here between flattening these
datatypes into @MutableArray ix ix (MutableArray# s elt)@ and using
it as is?  As I see it, the former uses slightly less heap and
provides faster access to the individual parts of the bounds while the
code used has the benefit of providing a ready-made @(lo, hi)@ pair as
required by many array-related functions.  Which wins? Is the
difference significant (probably not).

Idle AJG answer: When I looked at the outputted code (though it was 2
years ago) it seems like you often needed the tuple, and we build
it frequently. Now we've got the overloading specialiser things
might be different, though.

\begin{code}
newArray :: Ix ix => (ix,ix) -> elt -> ST s (MutableArray s ix elt)

{-# SPECIALIZE newArray      :: IPr       -> elt -> ST s (MutableArray s Int elt),
				(IPr,IPr) -> elt -> ST s (MutableArray s IPr elt)
  #-}
newArray (l,u) init = ST $ \ s# ->
    case rangeSize (l,u)          of { I# n# ->
    case (newArray# n# init s#)   of { (# s2#, arr# #) ->
    (# s2#, MutableArray l u arr# #) }}



boundsOfArray     :: Ix ix => MutableArray s ix elt -> (ix, ix)  
{-# SPECIALIZE boundsOfArray     :: MutableArray s Int elt -> IPr #-}
boundsOfArray     (MutableArray     l u _) = (l,u)

readArray   	:: Ix ix => MutableArray s ix elt -> ix -> ST s elt 
{-# SPECIALIZE readArray       :: MutableArray s Int elt -> Int -> ST s elt,
				  MutableArray s IPr elt -> IPr -> ST s elt
  #-}

readArray (MutableArray l u arr#) n = ST $ \ s# ->
    case (index (l,u) n)		of { I# n# ->
    case readArray# arr# n# s#		of { (# s2#, r #) ->
    (# s2#, r #) }}

writeArray  	 :: Ix ix => MutableArray s ix elt -> ix -> elt -> ST s () 
{-# SPECIALIZE writeArray  	:: MutableArray s Int elt -> Int -> elt -> ST s (),
				   MutableArray s IPr elt -> IPr -> elt -> ST s ()
  #-}

writeArray (MutableArray l u arr#) n ele = ST $ \ s# ->
    case index (l,u) n		    	    of { I# n# ->
    case writeArray# arr# n# ele s# 	    of { s2# ->
    (# s2#, () #) }}
\end{code}


%*********************************************************
%*							*
\subsection{Moving between mutable and immutable}
%*							*
%*********************************************************

\begin{code}
freezeArray	  :: Ix ix => MutableArray s ix elt -> ST s (Array ix elt)
{-# SPECIALISE freezeArray :: MutableArray s Int elt -> ST s (Array Int elt),
			      MutableArray s IPr elt -> ST s (Array IPr elt)
  #-}

freezeArray (MutableArray l u arr#) = ST $ \ s# ->
    case rangeSize (l,u)     of { I# n# ->
    case freeze arr# n# s# of { (# s2#, frozen# #) ->
    (# s2#, Array l u frozen# #) }}
  where
    freeze  :: MutableArray# s ele	-- the thing
	    -> Int#			-- size of thing to be frozen
	    -> State# s			-- the Universe and everything
	    -> (# State# s, Array# ele #)
    freeze m_arr# n# s#
      = case newArray# n# init s#	      of { (# s2#, newarr1# #) ->
	case copy 0# n# m_arr# newarr1# s2#   of { (# s3#, newarr2# #) ->
	unsafeFreezeArray# newarr2# s3#
	}}
      where
	init = error "freezeArray: element not copied"

	copy :: Int# -> Int#
	     -> MutableArray# s ele 
	     -> MutableArray# s ele
	     -> State# s
	     -> (# State# s, MutableArray# s ele #)

	copy cur# end# from# to# st#
	  | cur# ==# end#
	    = (# st#, to# #)
	  | otherwise
	    = case readArray#  from# cur#     st#  of { (# s1#, ele #) ->
	      case writeArray# to#   cur# ele s1# of { s2# ->
	      copy (cur# +# 1#) end# from# to# s2#
	      }}

unsafeFreezeArray     :: Ix ix => MutableArray s ix elt -> ST s (Array ix elt)  
unsafeFreezeArray (MutableArray l u arr#) = ST $ \ s# ->
    case unsafeFreezeArray# arr# s# of { (# s2#, frozen# #) ->
    (# s2#, Array l u frozen# #) }

--This takes a immutable array, and copies it into a mutable array, in a
--hurry.

thawArray :: Ix ix => Array ix elt -> ST s (MutableArray s ix elt)
{-# SPECIALISE thawArray :: Array Int elt -> ST s (MutableArray s Int elt),
			    Array IPr elt -> ST s (MutableArray s IPr elt)
  #-}

thawArray (Array l u arr#) = ST $ \ s# ->
    case rangeSize (l,u) of { I# n# ->
    case thaw arr# n# s# of { (# s2#, thawed# #) ->
    (# s2#, MutableArray l u thawed# #)}}
  where
    thaw  :: Array# ele			-- the thing
	    -> Int#			-- size of thing to be thawed
	    -> State# s			-- the Universe and everything
	    -> (# State# s, MutableArray# s ele #)

    thaw arr1# n# s#
      = case newArray# n# init s#	      of { (# s2#, newarr1# #) ->
	copy 0# n# arr1# newarr1# s2# }
      where
	init = error "thawArray: element not copied"

	copy :: Int# -> Int#
	     -> Array# ele 
	     -> MutableArray# s ele
	     -> State# s
	     -> (# State# s, MutableArray# s ele #)

	copy cur# end# from# to# st#
	  | cur# ==# end#
	    = (# st#, to# #)
	  | otherwise
	    = case indexArray#  from# cur#        of { (# ele #) ->
	      case writeArray# to#   cur# ele st# of { s1# ->
	      copy (cur# +# 1#) end# from# to# s1#
	      }}

-- this is a quicker version of the above, just flipping the type
-- (& representation) of an immutable array. And placing a
-- proof obligation on the programmer.
unsafeThawArray :: Ix ix => Array ix elt -> ST s (MutableArray s ix elt)
unsafeThawArray (Array l u arr#) = ST $ \ s# ->
   case unsafeThawArray# arr# s# of
      (# s2#, marr# #) -> (# s2#, MutableArray l u marr# #)
\end{code}
