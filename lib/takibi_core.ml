(** Shared vocabulary for the long-term Takibi Core.

    Only [Delta.Legacy_flow] and [Delta.Region_taint] are wired into the
    surface checker today. The other types establish the boundary that later
    elaboration slices will target; they deliberately do not claim that the
    current surface AST has already been elaborated into Core. See
    TAKIBI_CORE.md. *)

module Multiplicity = struct
  type t = Unrestricted | Affine | Linear

  let allows_weakening = function
    | Unrestricted | Affine -> true
    | Linear -> false

  let allows_contraction = function
    | Unrestricted -> true
    | Affine | Linear -> false
end

module Gamma = struct
  (** A runtime place and its type. [ownership] records whether elaboration
      also creates an ownership permission in Delta. *)
  type ('place, 'ty) binding = {
    place : 'place;
    ty : 'ty;
    ownership : Multiplicity.t;
  }
end

module Delta = struct
  type multiplicity = Affine | Linear

  (** A permission binding in the future Core. Permission payloads may be
      abstract views, ownership of a Gamma place, or separation predicates. *)
  type ('place, 'permission) binding = {
    subject : 'place;
    permission : 'permission;
    multiplicity : multiplicity;
  }

  (** Behavior-preserving analysis domain for the current affine/linear
      surface checker.

      [maybe_consumed] is unioned at a branch join; [must_be_consumed] is
      intersected. The former supports the at-most-once check shared by
      affine and linear values. The latter supports linear all-path
      obligations; standard affine weakening does not consult it. This is
      intentionally named Legacy_flow: final Delta will track available
      permissions and explicit consume/produce transitions. *)
  module Legacy_flow (Place : Set.OrderedType) : sig
    module Places : Set.S with type elt = Place.t

    type t

    val empty : t
    val consume : Place.t -> t -> t
    val produce : Place.t -> t -> t
    val join_branches : t -> t -> t
    val may_be_consumed : Place.t -> t -> bool
    val is_consumed_on_all_paths : Place.t -> t -> bool
    val maybe_consumed : t -> Places.t
    val must_be_consumed : t -> Places.t
  end = struct
    module Places = Set.Make (Place)

    type t = {
      maybe_consumed : Places.t;
      must_be_consumed : Places.t;
    }

    let empty = {
      maybe_consumed = Places.empty;
      must_be_consumed = Places.empty;
    }

    let consume place flow = {
      maybe_consumed = Places.add place flow.maybe_consumed;
      must_be_consumed = Places.add place flow.must_be_consumed;
    }

    let produce place flow = {
      maybe_consumed = Places.remove place flow.maybe_consumed;
      must_be_consumed = Places.remove place flow.must_be_consumed;
    }

    let join_branches left right = {
      maybe_consumed = Places.union left.maybe_consumed right.maybe_consumed;
      must_be_consumed =
        Places.inter left.must_be_consumed right.must_be_consumed;
    }

    let may_be_consumed place flow = Places.mem place flow.maybe_consumed
    let is_consumed_on_all_paths place flow =
      Places.mem place flow.must_be_consumed

    let maybe_consumed flow = flow.maybe_consumed
    let must_be_consumed flow = flow.must_be_consumed
  end

  (** Owner-derived region taint for the surface checker (TAKIBI_CORE.md
      post-Slice-6 order item 1, issue #106).

      Maps a local variable NAME to the set of owner places its value was
      derived from (via a call whose return type carries a region annotation,
      or by alias/subslice propagation from such a value). The check itself
      is lazy: a tainted name is rejected at USE time when any of its owner
      places is in Legacy_flow's [maybe_consumed], so branch joins need only
      the pointwise union below -- consumption merging is already handled by
      Legacy_flow's own union. Function-local by construction, like the rest
      of the current Delta tracking. *)
  module Region_taint (Places : Set.S) : sig
    type t

    val empty : t
    val get : string -> t -> Places.t
    val set : string -> Places.t -> t -> t
    val join_branches : t -> t -> t
  end = struct
    module M = Map.Make (String)

    type t = Places.t M.t

    let empty = M.empty
    let get name taints =
      Option.value (M.find_opt name taints) ~default:Places.empty
    let set name places taints =
      if Places.is_empty places then M.remove name taints
      else M.add name places taints
    let join_branches = M.union (fun _ a b -> Some (Places.union a b))
  end
end

module Phi = struct
  type relation = Eq | Ne | Lt | Le | Gt | Ge

  (** Pure propositions are parameterized by the term and abstract-atom
      languages so the first indexed-resource slice need not commit the Core
      to the current Types.ty representation. *)
  type ('term, 'atom) proposition =
    | True
    | False
    | Atom of 'atom
    | Compare of relation * 'term * 'term
    | Not of ('term, 'atom) proposition
    | And of ('term, 'atom) proposition list
    | Or of ('term, 'atom) proposition list
end

module Epsilon = struct
  type builtin =
    | May_block
    | May_suspend
    | Interrupt_handler
    | Atomic_region
    | Mmio

  module Builtins = Set.Make (struct
    type t = builtin
    let compare = compare
  end)

  type 'custom t = {
    builtins : Builtins.t;
    custom : 'custom list;
  }

  let empty = { builtins = Builtins.empty; custom = [] }
end

type ('gamma, 'delta, 'phi) contexts = {
  gamma : 'gamma;
  delta : 'delta;
  phi : 'phi;
}

type ('contexts, 'effects) transition = {
  before : 'contexts;
  after : 'contexts;
  effects : 'effects;
}
