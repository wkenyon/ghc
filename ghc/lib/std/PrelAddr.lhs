%
% (c) The AQUA Project, Glasgow University, 1994-1998
%

\section[PrelAddr]{Module @PrelAddr@}

\begin{code}
{-# OPTIONS -fno-implicit-prelude #-}

module PrelAddr (
	  Addr(..)
	, nullAddr			-- :: Addr
	, plusAddr			-- :: Addr -> Int -> Addr
	, indexAddrOffAddr	        -- :: Addr -> Int -> Addr

	, Word(..)
	, wordToInt

	, Word64(..)
	, Int64(..)
   ) where

import PrelGHC
import PrelBase
\end{code}

\begin{code}
data Addr = A# Addr# 	deriving (Eq, Ord)
data Word = W# Word# 	deriving (Eq, Ord)

nullAddr :: Addr
nullAddr = A# (int2Addr# 0#)

plusAddr :: Addr -> Int -> Addr
plusAddr (A# addr) (I# off) = A# (int2Addr# (addr2Int# addr +# off))

instance CCallable Addr
instance CReturnable Addr

instance CCallable Word
instance CReturnable Word

wordToInt :: Word -> Int
wordToInt (W# w#) = I# (word2Int# w#)

#if WORD_SIZE_IN_BYTES == 8
data Word64 = W64# Word#
data Int64  = I64# Int#
#else
data Word64 = W64# Word64# --deriving (Eq, Ord) -- Glasgow extension
data Int64  = I64# Int64#  --deriving (Eq, Ord) -- Glasgow extension
#endif

instance CCallable   Word64
instance CReturnable Word64

instance CCallable   Int64
instance CReturnable Int64

indexAddrOffAddr   :: Addr -> Int -> Addr
indexAddrOffAddr (A# addr#) n
  = case n  	    	    	    	of { I# n# ->
    case indexAddrOffAddr# addr# n# 	of { r# ->
    (A# r#)}}

\end{code}

