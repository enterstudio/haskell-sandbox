{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts #-}

module Main where

import           Control.Lens           hiding (Const)
import           Control.Monad.Except
import           Control.Monad.State
import           Data.Bits            (xor)
import           Data.Char            (ord)
import qualified Data.Map             as M
import           Data.Maybe           (fromJust)
import qualified Data.Vector          as V
import           GHC.Generics
import           System.Environment       (getArgs)
import           System.Exit              (die)
import           System.IO
import           Text.Parsec          hiding (optional)
import           Text.Parsec.Expr
import           Text.Printf

type UserString = String

data Token = CommandToken Command | Comment String | Whitespace | Label String

data Command =
  Break |
  PrintByte |
  PrintNum |
  ReadNum |
  ReadByte |
  Dup |
  PushVar String |
  PushConst Int |
  StoreVar String |
  Call |
  Jump |
  Add |
  Sub |
  Mod |
  Xor |
  Vstore |
  Vload |
  Ifz |
  Ifg |
  Noop |
  Exit
  deriving (Show)

data Program = Program {
  _commands :: V.Vector Command,
  _stack :: [Int],
  _variables :: M.Map String Int,
  _vstore :: M.Map Int Int,
  _instructionPointer :: Int
} deriving (Show, Generic)

makeLenses ''Program

type ParseResult = Either ParseError Program

type Eval a = ExceptT String (StateT Program IO) a

main :: IO ()
main = do
  args  <- getArgs

  sourceFile <- case args of
                  [x] -> return x
                  _   -> die "Usage: run17 src.17"

  contents <- readFile sourceFile

  case parse17 contents of
    Left x  -> print x
    Right x -> do
      --print x
      runEval x


---
--- EVALUATION
---

runEval :: Program -> IO ()
runEval p = do
  _ <- runStateT (runExceptT eval) p
  return ()

eval :: Eval ()
eval = do
  i <- use instructionPointer
  nextCommand <- uses commands (V.!? i)

  case nextCommand of
    Nothing -> do
      --liftIO . putStrLn $ ""
      --liftIO . putStrLn $ show p
      return ()
    Just c -> do
      --liftIO . putStrLn $ printf "%d: %s\t%s" (instructionPointer p) (show c) (show $ stack p)
      instructionPointer += 1
      evalCommand c
      eval

evalCommand :: Command -> Eval ()
evalCommand Noop = return ()
evalCommand Break = do
  p <- get
  liftIO $ putStrLn "--- BREAK"
  liftIO . print $ p
  readInput
  return ()

-- TODO: Proper error handling
evalCommand ReadNum = readInput >>= pushStack . read
evalCommand ReadByte = readChar >>= pushStack . ord

evalCommand PrintByte = printChar "%c"
evalCommand PrintNum  = printChar "%d"

evalCommand Exit = instructionPointer <~ uses commands length

evalCommand Dup = do
  x <- popStack
  pushStack x
  pushStack x

evalCommand (StoreVar var) = do
  x <- popStack

  variables %= M.insert var x

evalCommand (PushVar var) = do
  value <- uses variables $ M.lookup var

  case value of
    Nothing -> throwError ("Failed to lookup: " ++ var)
    Just x  -> pushStack x

evalCommand Vstore = do
  v <- popStack
  k <- popStack

  vstore %= M.insert k v

evalCommand Vload = do
  k <- popStack
  value <- uses vstore $ M.lookup k

  case value of
    Nothing -> throwError ("No entry in vstore for: " ++ show k)
    Just x  -> pushStack x

evalCommand (PushConst x) = pushStack x

evalCommand Jump = do
  target <- popStack

  instructionPointer .= target

evalCommand Call = do
  current <- use instructionPointer
  target  <- popStack

  pushStack current
  instructionPointer .= target

evalCommand Add = binaryOp (+)
evalCommand Sub = binaryOp $ flip (-)
evalCommand Mod = binaryOp $ flip mod
evalCommand Xor = binaryOp xor

evalCommand Ifz = ifc (0 ==)
evalCommand Ifg = ifc (0 <)

readInput :: Eval String
readInput = do
  liftIO $ hSetEcho stdout True
  liftIO getLine

readChar :: Eval Char
readChar = do
  liftIO $ hSetEcho stdout False
  liftIO getChar

pushStack :: Int -> Eval ()
pushStack x = stack %= (:) x

popStack :: Eval Int
popStack = do
  p <- get
  
  case _stack p of
    (x:xs) -> do
      stack .= xs
      return x
    _      -> throwError "Cannot pop an empty stack"

binaryOp f = do
  a <- popStack
  b <- popStack

  pushStack $ f a b

ifc f = do
  if_f <- popStack
  if_t <- popStack
  v    <- popStack

  let target = if f v then if_t else if_f

  pushStack target
  evalCommand Jump

printChar fstr = do
  byte <- popStack
  liftIO . putStr $ printf fstr byte
  liftIO . hFlush $ stdout 

--
-- PARSING
--

emptyProgram = Program {
  _variables          = M.empty,
  _vstore             = M.empty,
  _commands           = mzero,
  _stack              = mzero,
  _instructionPointer = 0
}

parse17 :: UserString -> ParseResult
parse17 input = runParser grammar () input input

grammar = do
  stream <- many $
                  comment
              <|> try label17
              <|> command
              <|> constant
              <|> variable
              <|> whitespace

  return emptyProgram {
    _variables          = filterLabels 0 M.empty stream,
    _commands           = V.fromList (identifyStores . filterCommands $ stream)
  }

identifyStores :: [Command] -> [Command]
identifyStores (PushVar x:StoreVar y:cs)= StoreVar x:Noop:identifyStores cs
identifyStores (StoreVar y:cs) = undefined -- parse error
identifyStores (c:cs) = c:identifyStores cs
identifyStores [] = []

filterLabels :: Int -> M.Map String Int -> [Token] -> M.Map String Int
filterLabels i m (CommandToken c:xs) = filterLabels (i+1) m xs
filterLabels i m (Label c:xs) = filterLabels i (M.insert c i m) xs
filterLabels i m (x:xs) = filterLabels i m xs
filterLabels i m [] = m

filterCommands :: [Token] -> [Command]
filterCommands (CommandToken c:xs) = c:filterCommands xs
filterCommands (x:xs) = filterCommands xs
filterCommands [] = []

whitespace = do
  many1 space
  return Whitespace

comment = do
  string "/*"
  x <- manyTill anyChar (try (string "*/"))
  return $ Comment x

label17 = do
  x <- many1 (alphaNum <|> char '_')
  string ":"

  return $ Label x

command =
      makeCommand "print_byte" PrintByte
  <|> makeCommand "print_num" PrintNum
  <|> makeCommand "read_byte" ReadByte
  <|> makeCommand "read_num" ReadNum
  <|> makeCommand "exit" Exit
  <|> makeCommand "dup" Dup
  <|> makeCommand "jump" Jump
  <|> makeCommand "call" Call
  <|> makeCommand "add" Add
  <|> makeCommand "sub" Sub
  <|> makeCommand "mod" Mod
  <|> makeCommand "xor" Xor
  <|> makeCommand "vstore" Vstore
  <|> makeCommand "vload" Vload
  <|> makeCommand "ifz" Ifz
  <|> makeCommand "ifg" Ifg
  <|> makeCommand "break" Break
  <|> makeCommand "store" (StoreVar "")

makeCommand x t = do
  try $ do
    string x
    whitespace

  return $ CommandToken t
 
constant = do
  x <- many1 digit
  return $ CommandToken (PushConst $ read x)

variable = do
  x <- letter
  y <- many (alphaNum <|> char '_')
  return $ CommandToken (PushVar (x:y))
