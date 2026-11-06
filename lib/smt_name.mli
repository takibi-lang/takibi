(* The names of the integer constants the compiler writes into z3
   obligations (GitHub issue #1394).

   A name is abstract: the only way to make one is a constructor below,
   and every constructor goes through one injective encoding, so two
   distinct things never become one z3 constant. #1372 found two encoders
   that were not injective (init_pred's atoms mapped every punctuation
   character to '_'; #1232's enum constants joined two names with "__"),
   and either let z3 prove an obligation from an equality the program
   never had. A new kind of name is a new constructor here, not a
   [Printf.sprintf] at the call site. *)

type t

(* An init_pred atom: a binding or path name, any characters. *)
val atom : string -> t

(* A static type parameter or unification variable, by its id. *)
val param : int -> t
val var : int -> t

(* A global's address and an enum case, uninterpreted (#1232). *)
val global : string -> t
val enum : string -> string -> t

(* The SMT-LIB symbol. *)
val to_string : t -> string
