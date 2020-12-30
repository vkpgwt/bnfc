{-
    BNF Converter: Pretty-printer generator
    Copyright (C) 2005  Author:  Kristofer Johannisson

-}

-- based on BNFC Haskell backend

{-# LANGUAGE OverloadedStrings #-}

module BNFC.Backend.OCaml.CFtoOCamlPrinter (cf2Printer, prtFun) where

import Prelude hiding ((<>))

import Data.Char(toLower)
import Data.List (intersperse, sortBy)
import Data.Maybe (fromJust)

import BNFC.CF
import BNFC.Utils
import BNFC.Backend.OCaml.OCamlUtil
import BNFC.PrettyPrint
import BNFC.Backend.Haskell.CFtoPrinter (compareRules)


-- derive pretty-printer from a BNF grammar. AR 15/2/2002
cf2Printer :: String -> ModuleName -> CF -> String
cf2Printer _name absMod cf = unlines [
  prologue,
  charRule cf,
  integerRule cf,
  doubleRule cf,
  stringRule cf,
  if hasIdent cf then identRule absMod cf else "",
  unlines [ownPrintRule absMod cf own | (own,_) <- tokenPragmas cf],
  rules absMod cf
  ]


prologue :: String
prologue = unlines [
  "(* pretty-printer generated by the BNF converter *)",
  "",
  "open Printf",
  "",
  "(* We use string buffers for efficient string concatenation.",
  "   A document takes a buffer and an indentation, has side effects on the buffer",
  "   and returns a new indentation. The indentation argument indicates the level",
  "   of indentation to be used if a new line has to be started (because of what is",
  "   already in the buffer) *)",
  "type doc = Buffer.t -> int -> int",
  "",
  "let rec printTree (printer : int -> 'a -> doc) (tree : 'a) : string = ",
  "    let buffer_init_size = 64 (* you may want to change this *)",
  "    in let buffer = Buffer.create buffer_init_size",
  "    in ",
  "        let _ = printer 0 tree buffer 0 in (* discard return value *)",
  "        Buffer.contents buffer",
  "",
  "let indent_width = 4",
  "",
  "let indent (i: int) : string = \"\\n\" ^ String.make i ' '",
  "",
  "(* To avoid dependency on package extlib, which has",
  "   Extlib.ExtChar.Char.is_whitespace, we employ the following awkward",
  "   way to check a character for whitespace.",
  "   Note: String.trim exists in the core libraries since Ocaml 4.00. *)",
  "let isWhiteSpace (c: char) : bool = String.trim (String.make 1 c) = \"\"",
  "",
  "(* this render function is written for C-style languages, you may want to change it *)",
  "let render (s : string) : doc = fun buf i -> ",
  "    (* invariant: last char of the buffer is never whitespace *)",
  "    let n = Buffer.length buf in",
  "    let last = if n = 0 then None else Some (Buffer.nth buf (n-1)) in",
  "    let whitespace = match last with",
  "        None -> \"\" ",
  "      | Some '{' -> indent i",
  "      | Some '}' -> (match s with",
  "            \";\" -> \"\"",
  "          | _ -> indent i)",
  "      | Some ';' -> indent i",
  "      | (Some '[') |  (Some '(') -> \"\"",
  "      | Some c -> if isWhiteSpace c then \"\" else (match s with",
  "            \",\" | \")\" | \"]\" -> \"\"",
  "           | _ -> if String.trim s = \"\" then \"\" else \" \") in",
  "    let newindent = match s with",
  "        \"{\" -> i + indent_width",
  "      | \"}\" -> i - indent_width",
  "      | _ -> i in",
  "    Buffer.add_string buf whitespace;",
  "    Buffer.add_string buf s;",
  "    newindent",
  "",
  "let emptyDoc : doc = fun buf i -> i",
  "",
  "let concatD (ds : doc list) : doc = fun buf i -> ",
  "    List.fold_left (fun accIndent elemDoc -> elemDoc buf accIndent) (emptyDoc buf i) ds",
  "",
  "let parenth (d:doc) : doc = concatD [render \"(\"; d; render \")\"]",
  "",
  "let prPrec (i:int) (j:int) (d:doc) : doc = if j<i then parenth d else d",
  ""
  ]

charRule cf = unlines [
    "let rec prtChar (_:int) (c:char) : doc = render (\"'\" ^ Char.escaped c ^ \"'\")",
    ifList cf (TokenCat catChar),
    ""
    ]

integerRule cf = unlines [
    "let rec prtInt (_:int) (i:int) : doc = render (string_of_int i)",
    ifList cf (TokenCat catInteger),
    ""
    ]

doubleRule cf = unlines [
    "let rec prtFloat (_:int) (f:float) : doc = render (sprintf \"%.15g\" f)",
    ifList cf (TokenCat catDouble),
    ""
    ]

stringRule cf = unlines [
    "let rec prtString (_:int) (s:string) : doc = render (\"\\\"\" ^ String.escaped s ^ \"\\\"\")",
    ifList cf (TokenCat catString),
    ""
    ]

identRule absMod cf = ownPrintRule absMod cf catIdent

ownPrintRule :: ModuleName -> CF -> TokenCat -> String
ownPrintRule absMod cf own = unlines $ [
  "let rec" +++ prtFun (TokenCat own) +++ "_ (" ++ absMod ++ "." ++ own ++ posn ++ ") : doc = render i",
  ifList cf (TokenCat own)
  ]
 where
   posn = if isPositionCat cf own then " (_,i)" else " i"

-- copy and paste from CFtoTemplate

rules :: ModuleName -> CF -> String
rules absMod cf = unlines $ mutualDefs $
  map (\(s,xs) -> case_fun absMod s (map toArgs xs) ++ ifList cf s) $ cf2data cf
 where
   reserved = "i":"e":reservedOCaml
   toArgs (cons,args) = ((cons, mkNames reserved LowerCase (map var args)), ruleOf cons)
   var (ListCat c)  = var c ++ "s"
   var (Cat "Ident")   = "id"
   var (Cat "Integer") = "n"
   var (Cat "String")  = "str"
   var (Cat "Char")    = "c"
   var (Cat "Double")  = "d"
   var xs        = map toLower (show xs)
   ruleOf s = fromJust $ lookupRule (noPosition s) (cfgRules cf)

--- case_fun :: Cat -> [(Constructor,Rule)] -> String
case_fun absMod cat xs = unlines [
--  "instance Print" +++ cat +++ "where",
  prtFun cat +++"(i:int)" +++ "(e : " ++ fixTypeQual absMod cat ++ ") : doc = match e with",
  unlines $ insertBar $ map (\ ((c,xx),r) ->
    "   " ++ absMod ++ "." ++ c +++ mkTuple xx +++ "->" +++
    "prPrec i" +++ show (precCat (fst r)) +++ mkRhs xx (snd r)) xs
  ]

-- ifList cf cat = mkListRule $ nil cat ++ one cat ++ cons cat where
--   nil cat  = ["    []    -> " ++ mkRhs [] its |
--                             Rule f c its <- rulesOfCF cf, isNilFun f , normCatOfList c == cat]
--   one cat  = ["  | [x]   -> " ++ mkRhs ["x"] its |
--                             Rule f c its <- rulesOfCF cf, isOneFun f , normCatOfList c == cat]
--   cons cat = ["  | x::xs -> " ++ mkRhs ["x","xs"] its |
--                             Rule f c its <- rulesOfCF cf, isConsFun f , normCatOfList c == cat]
--   mkListRule [] = ""
--   mkListRule rs = unlines $ ("and prt" ++ fixTypeUpper cat ++ "ListBNFC" +++ "_ es : doc = match es with"):rs

ifList :: CF -> Cat -> String
ifList cf cat = case cases of
    []        -> ""
    first:rest -> render $ vcat
        [ "and prt" <> text (fixTypeUpper cat)  <> "ListBNFC i es : doc = match (i, es) with"
        , nest 4 first
        , nest 2 $ vcat (map ("|" <+>) rest)
        ]
  where
    rules = sortBy compareRules $ rulesForNormalizedCat cf (ListCat cat)
    cases = [ d | r <- rules, let d = mkPrtListCase r, not (isEmpty d) ]


-- | Pattern match on the list constructor and the coercion level
--
-- >>> mkPrtListCase (npRule "[]" (ListCat (Cat "Foo")) [] Parsable)
-- (_,[]) -> (concatD [])
--
-- >>> mkPrtListCase (npRule "(:[])" (ListCat (Cat "Foo")) [Left (Cat "Foo")] Parsable)
-- (_,[x]) -> (concatD [prtFoo 0 x])
--
-- >>> mkPrtListCase (npRule "(:)" (ListCat (Cat "Foo")) [Left (Cat "Foo"), Left (ListCat (Cat "Foo"))] Parsable)
-- (_,x::xs) -> (concatD [prtFoo 0 x ; prtFooListBNFC 0 xs])
--
-- >>> mkPrtListCase (npRule "[]" (ListCat (CoercCat "Foo" 2)) [] Parsable)
-- (2,[]) -> (concatD [])
--
-- >>> mkPrtListCase (npRule "(:[])" (ListCat (CoercCat "Foo" 2)) [Left (CoercCat "Foo" 2)] Parsable)
-- (2,[x]) -> (concatD [prtFoo 2 x])
--
-- >>> mkPrtListCase (npRule "(:)" (ListCat (CoercCat "Foo" 2)) [Left (CoercCat "Foo" 2), Left (ListCat (CoercCat "Foo" 2))] Parsable)
-- (2,x::xs) -> (concatD [prtFoo 2 x ; prtFooListBNFC 2 xs])
--
mkPrtListCase :: Rule -> Doc
mkPrtListCase (Rule f (WithPosition _ (ListCat c)) rhs _)
  | isNilFun f  = parens (precPattern <> "," <> "[]") <+> "->" <+> body
  | isOneFun f  = parens (precPattern <> "," <> "[x]") <+> "->" <+> body
  | isConsFun f = parens (precPattern <> "," <>"x::xs") <+> "->" <+> body
  | otherwise = empty -- (++) constructor
  where
    precPattern = case precCat c of 0 -> "_" ; p -> integer p
    body = text $ mkRhs ["x", "xs"] rhs
mkPrtListCase _ = error "mkPrtListCase undefined for non-list categories"

mkRhs args its =
  "(concatD [" ++ unwords (intersperse ";" (mk args its)) ++ "])"
 where
  mk (arg:args) (Left c : items)  = (prt c +++ arg)        : mk args items
  mk args       (Right s : items) = ("render " ++ mkEsc s) : mk args items
  mk _ _ = []
  prt c = prtFun c +++ show (precCat c)

prtFun :: Cat -> String
prtFun (ListCat c) = prtFun c ++ "ListBNFC"
prtFun c = "prt" ++ fixTypeUpper (normCat c)
