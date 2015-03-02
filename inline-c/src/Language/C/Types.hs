{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
module Language.C.Types
  ( -- * Types
    P.Id
  , P.TypeQual(..)
  , TypeSpec(..)
  , Type(..)
  , P.ArraySize
  , Sign(..)
  , Declaration(..)

    -- * Parsing
  , parseDeclaration
  , parseAbstractDeclaration
  , P.parseIdentifier

    -- * Prettying
  , prettyParams
  ) where

import qualified Language.C.Types.Parse as P
import           Control.Monad (when, unless, forM)
import           Data.Maybe (fromMaybe)
import           Data.List (partition)
import           Text.PrettyPrint.ANSI.Leijen ((<+>))
import qualified Text.PrettyPrint.ANSI.Leijen as PP
import           Data.Monoid ((<>))
import           Text.Trifecta

------------------------------------------------------------------------
-- Proper types

data TypeSpec
  = Void
  | Char (Maybe Sign)
  | Short Sign
  | Int Sign
  | Long Sign
  | LLong Sign
  | Float
  | Double
  | LDouble
  | TypeName P.Id
  | Struct P.Id
  | Enum P.Id
  deriving (Show, Eq)

data Type
  = TypeSpec TypeSpec
  | Ptr [P.TypeQual] Type
  | Array (Maybe P.ArraySize) Type
  | Proto Type [Declaration P.Id]
  deriving (Show, Eq)

data Sign
  = Signed
  | Unsigned
  deriving (Show, Eq)

-- | If the 'P.Id' is not present, the declaration is abstract.
data Declaration a = Declaration a [P.TypeQual] Type
  deriving (Show, Eq, Functor)

------------------------------------------------------------------------
-- Conversion

data ConversionErr
  = MultipleDataTypes [P.TypeSpec]
  | IllegalSpecifiers String [P.TypeSpec]
  deriving (Show, Eq)

failConversion :: ConversionErr -> Either ConversionErr a
failConversion = Left

processParsedDecl :: P.Declaration -> Either ConversionErr (Declaration (Maybe P.Id))
processParsedDecl (P.Declaration (P.DeclarationSpec quals pTySpecs) declarator) = do
  tySpec <- processParsedTySpecs pTySpecs
  (s, type_) <- processDeclarator (TypeSpec tySpec) declarator
  return $ Declaration s quals type_

processParsedTySpecs :: [P.TypeSpec] -> Either ConversionErr TypeSpec
processParsedTySpecs pTySpecs = do
  -- Split data type and specifiers
  let (dataTypes, specs) =
        partition (\x -> not (x `elem` [P.Signed, P.Unsigned, P.Long, P.Short])) pTySpecs
  let illegalSpecifiers s = failConversion $ IllegalSpecifiers s specs
  -- Find out sign, if present
  mbSign0 <- case filter (== P.Signed) specs of
    []  -> return Nothing
    [_] -> return $ Just Signed
    _:_ -> illegalSpecifiers "conflicting/duplicate sign information"
  mbSign <- case (mbSign0, filter (== P.Unsigned) specs) of
    (Nothing, []) -> return Nothing
    (Nothing, [_]) -> return $ Just Unsigned
    (Just b, []) -> return $ Just b
    _ -> illegalSpecifiers "conflicting/duplicate sign information"
  let sign = fromMaybe Signed mbSign
  -- Find out length
  let longs = length $ filter (== P.Long) specs
  let shorts = length $ filter (== P.Short) specs
  when (longs > 0 && shorts > 0) $ illegalSpecifiers "both long and short"
  -- Find out data type
  dataType <- case dataTypes of
    [x] -> return x
    [] | longs > 0 || shorts > 0 -> return P.Int
    _ -> failConversion $ MultipleDataTypes dataTypes
  -- Check if things are compatible with one another
  let checkNoSpecs =
        unless (null specs) $ illegalSpecifiers "expecting no specifiers"
  let checkNoLength =
        when (longs > 0 || shorts > 0) $ illegalSpecifiers "unexpected long/short"
  case dataType of
    P.TypeName s -> do
      checkNoSpecs
      return $ TypeName s
    P.Struct s -> do
      checkNoSpecs
      return $ Struct s
    P.Enum s -> do
      checkNoSpecs
      return $ Enum s
    P.Void -> do
      checkNoSpecs
      return Void
    P.Char -> do
      checkNoLength
      return $ Char mbSign
    P.Int | longs == 0 && shorts == 0 -> do
      return $ Int sign
    P.Int | longs == 1 -> do
      return $ Long sign
    P.Int | longs == 2 -> do
      return $ LLong sign
    P.Int | shorts == 1 -> do
      return $ Short sign
    P.Int -> do
      illegalSpecifiers "too many long/short"
    P.Float -> do
      checkNoLength
      return Float
    P.Double -> do
      if longs == 1
        then return LDouble
        else do
          checkNoLength         -- TODO `long double` is acceptable
          return Double
    _ -> do
      error $ "processParsedDecl: impossible: " ++ show dataType

processDeclarator
  :: Type -> P.Declarator -> Either ConversionErr (Maybe P.Id, Type)
processDeclarator ty declarator0 = case declarator0 of
  P.DeclaratorRoot mbS -> return (mbS, ty)
  P.Ptr quals declarator -> processDeclarator (Ptr quals ty) declarator
  P.Array mbSize declarator -> processDeclarator (Array mbSize ty) declarator
  P.Proto declarator declarations -> do
    args <- forM declarations $ \pDecl -> do
      Declaration (Just s) quals ty' <- processParsedDecl pDecl
      return $ Declaration s quals ty'
    processDeclarator (Proto ty args) declarator

------------------------------------------------------------------------
-- Parsing

parseDeclaration :: Parser (Declaration P.Id)
parseDeclaration = do
  pDecl <- P.parseDeclaration
  case processParsedDecl pDecl of
    Left e -> fail $ PP.displayS (PP.renderPretty 0.8 80 (PP.pretty e)) ""
    Right decl -> do
      Declaration (Just s) quals ty <- return decl
      return $ Declaration s quals ty

parseAbstractDeclaration :: Parser (Declaration ())
parseAbstractDeclaration = do
  pDecl <- P.parseAbstractDeclaration
  case processParsedDecl pDecl of
    Left e -> fail $ PP.displayS (PP.renderPretty 0.8 80 (PP.pretty e)) ""
    Right decl -> do
      Declaration Nothing quals ty <- return decl
      return $ Declaration () quals ty

------------------------------------------------------------------------
-- Pretty printing

instance PP.Pretty ConversionErr where
  pretty e = case e of
    MultipleDataTypes types ->
      "Multiple data types in declaration:" <+> PP.prettyList types
    IllegalSpecifiers msg specs ->
      "Illegal specifiers," <+> PP.text msg <> ":" <> PP.prettyList specs

instance PP.Pretty TypeSpec where
  pretty tySpec = case tySpec of
    Void -> "void"
    Char Nothing -> "char"
    Char (Just Signed) -> "signed char"
    Char (Just Unsigned) -> "unsigned char"
    Short Signed -> "short"
    Short Unsigned -> "unsigned short"
    Int Signed -> "int"
    Int Unsigned -> "unsigned"
    Long Signed -> "long"
    Long Unsigned -> "unsigned long"
    LLong Signed -> "long long"
    LLong Unsigned -> "unsigned long long"
    Float -> "float"
    Double -> "double"
    LDouble -> "long double"
    TypeName s -> PP.text s
    Struct s -> "struct" <+> PP.text s
    Enum s -> "enum" <+> PP.text s

instance PP.Pretty (Declaration ()) where
  pretty (Declaration () quals cTy) =
    PP.hsep (map PP.pretty quals) <+> PP.pretty cTy

instance PP.Pretty (Declaration P.Id) where
  pretty (Declaration s quals cTy) =
    PP.hsep (map PP.pretty quals) <+> prettyType (Just s) cTy

instance PP.Pretty Type where
  pretty = prettyType Nothing

data PrettyDirection
  = PrettyingRight
  | PrettyingLeft
  deriving (Eq, Show)

prettyParams :: [Declaration P.Id] -> PP.Doc
prettyParams = go . map PP.pretty
  where
    go [] = ""
    go (x : xs) = case xs of
      []  -> x
      _:_ -> x <> "," <+> go xs

prettyType :: Maybe P.Id -> Type -> PP.Doc
prettyType mbId ty00 =
  let base = case mbId of
        Nothing -> ""
        Just s -> PP.text s
  in go base PrettyingRight ty00
  where
    go :: PP.Doc -> PrettyDirection -> Type -> PP.Doc
    go base dir ty0 = case ty0 of
      TypeSpec spec -> PP.pretty spec <+> base
      Ptr quals ty ->
        let spacing = if null quals then "" else " "
        in go (PP.hsep (map PP.pretty quals) <> spacing <> "*" <> base) PrettyingLeft ty
      Array mbSize ty ->
        let parens' = if dir == PrettyingLeft then PP.parens else id
            sizeDoc = case mbSize of
              Nothing -> ""
              Just i -> PP.text $ show i
        in go (parens' base <> "[" <> sizeDoc <> "]") PrettyingRight ty
      Proto retType pars ->
        let parens' = if dir == PrettyingLeft then PP.parens else id
        in go (parens' base <> PP.parens (prettyParams pars)) PrettyingRight retType