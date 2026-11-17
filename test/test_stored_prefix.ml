(* Source-resolved acceptance controls for stored-address initialization frames. *)
open Takibi
let replace text old replacement =
  let re = Str.regexp_string old in
  Str.global_replace re replacement text
let check_file file reject transform () =
  Compilation_state.reset ();
  let source path = In_channel.with_open_bin ("../" ^ path) In_channel.input_all |> transform in
  let lexbuf path =
    let lexbuf = Lexing.from_string (source path) in
    lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname=path }; lexbuf in
  let resolved = Use_resolver.resolve
    ~parse_file:(fun path -> Parser.program Lexer.read (lexbuf path))
    ~prescan:(fun path -> Use_resolver.prescan_uses (lexbuf path))
    ["linux_user/growable_pool/fake_page_provider.tkb"; "test/" ^ file] in
  let parsed = List.concat_map snd resolved in
  let prog = Declared_type_resolver.run (Monomorphize.run
    (Dma_fixed_record.run (Publish_record.run (fst (Protocol_decl.extract parsed))))) in
  let errors = try ignore (Type_inf.infer_program prog); [] with
    | Types.TypeError (_,msg) -> [msg]
    | Types.MultiTypeError errors -> List.map snd errors in
  if reject then
    Alcotest.(check bool) "dependent use must reject" true
      (List.exists (fun msg -> try ignore (Str.search_forward (Str.regexp_string
        "init_links cannot prove initialized traversal") msg 0); true with Not_found -> false) errors)
  else Alcotest.(check (list string)) "valid store preserves initialization" [] errors
let check = check_file "stored_prefix_case.tkb"
let owner = check_file "owner_prefix_case.tkb"
let () = Alcotest.run "stored-prefix" ["acceptance",[
  Alcotest.test_case "derived payload frame" `Quick (check false Fun.id);
  Alcotest.test_case "table corruption" `Quick (check true (fun s -> replace s
    "    *growable_pool_ref_at(&pool, 0) = 7;"
    "    pool.chunk_data_base[0] = 0;\n    *growable_pool_ref_at(&pool, 0) = 7;"));
  Alcotest.test_case "reinitialization invalidates coverage" `Quick (check true (fun s -> replace s
    "    *growable_pool_ref_at(&pool, 0) = 7;"
    "    growable_pool_init(&pool);\n    *growable_pool_ref_at(&pool, 0) = 7;"));
  Alcotest.test_case "wrong chunk divisor" `Quick (check true (fun s -> replace s
    "index / SLOTS_PER_CHUNK" "index / 1"));
  Alcotest.test_case "missing explicit alignment" `Quick (check true (fun s -> replace s
    " align(65536)" ""));
]; "owner acceptance",[
  Alcotest.test_case "separate output state preserves owner frame" `Quick (owner false (fun s ->
    replace (replace s "fn main() !{unsafe} {"
      "let mut test_report_count: usize = 0;\nfn record_output() { test_report_count = test_report_count + 1; }\nfn main() !{unsafe} {")
      " *growable_pool_ref(&pool, owner) = 7;"
      " record_output();\n *growable_pool_ref(&pool, owner) = 7;"));
  Alcotest.test_case "provider mutation invalidates owner frame" `Quick (owner true (fun s -> replace s
    " *growable_pool_ref(&pool, owner) = 7;"
    " page_allocator_init();\n *growable_pool_ref(&pool, owner) = 7;"));
  Alcotest.test_case "derived owner payload frame" `Quick (owner false Fun.id);
  Alcotest.test_case "owner metadata corruption" `Quick (owner true (fun s -> replace s
    " *growable_pool_ref(&pool, owner) = 7;"
    " pool.chunk_data_base[0] = 0;\n *growable_pool_ref(&pool, owner) = 7;"));
  Alcotest.test_case "owner invalidated by reset" `Quick (owner true (fun s -> replace s
    " *growable_pool_ref(&pool, owner) = 7;"
    " growable_pool_init(&pool);\n *growable_pool_ref(&pool, owner) = 7;"));
  Alcotest.test_case "owner wrong chunk divisor" `Quick (owner true (fun s -> replace s
    "index / SLOTS_PER_CHUNK" "index / 1"));
  Alcotest.test_case "owner missing alignment" `Quick (owner true (fun s -> replace s
    " align(65536)" ""));
  Alcotest.test_case "renamed owner accessor" `Quick (owner false (fun s -> replace s
    "growable_pool_ref(" "pilot_owner_ref("));
]]
