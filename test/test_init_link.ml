(* Finite concrete-heap controls for linked initialization certificates.
   These tests check transfers and invalidation; they do not prove arbitrary
   heaps, bounds, termination or the compiler integration. *)
open Takibi

let tests = [
  Alcotest.test_case "Linked stores preserve concrete initialized traversal" `Quick
    (fun () ->
      let storage = ("local:1", ["links"]) in
      let safe mask links start =
        let rec walk seen i =
          i >= 3 || (mask land (1 lsl i) <> 0 &&
            (List.mem i seen || walk (i :: seen) links.(i))) in
        walk [] start in
      for mask = 0 to 7 do
        for code = 0 to 63 do
          let links = [|code mod 4; (code / 4) mod 4; code / 16|] in
          let state = List.fold_left (fun state i ->
            if safe mask links i then
              Init_link.establish state storage (string_of_int i)
            else state) Init_link.empty [0; 1; 2; 3] in
          for index = 0 to 2 do
            (match Init_link.load state ~full:(mask = 7) storage
                     ~index:(string_of_int index) ~target:"loaded" with
             | Some loaded ->
                 if not (safe mask links links.(index)) ||
                    not (Init_link.ready loaded ~full:false storage "loaded") then
                   Alcotest.fail "a successor load forged a traversal certificate"
             | None -> ());
            for successor = 0 to 3 do
              let after = Init_link.store state ~full:(mask = 7) storage
                  ~index:(string_of_int index) ~successor:(string_of_int successor) in
              let written = Array.copy links in written.(index) <- successor;
              for root = 0 to 3 do
                if Init_link.ready after ~full:(mask = 7) storage (string_of_int root)
                   && not (safe (mask lor (1 lsl index)) written root) then
                  Alcotest.failf "invalid certificate: mask=%d links=%d store[%d]=%d root=%d"
                    mask code index successor root
              done
            done
          done
        done
      done);
  Alcotest.test_case "Linked certificates cannot cross storage or a branch" `Quick
    (fun () ->
      let a = ("local:1", ["links"]) and b = ("local:2", ["links"]) in
      let state = Init_link.establish Init_link.empty a "head" in
      let state = Init_link.copy state ~target:"cursor" ~source:"head" in
      Alcotest.(check bool) "same storage" true (Init_link.ready state ~full:false a "cursor");
      Alcotest.(check bool) "other storage" false (Init_link.ready state ~full:false b "cursor");
      Alcotest.(check bool) "join cannot invent" false
        (Init_link.ready (Init_link.join state Init_link.empty) ~full:false a "cursor");
      Alcotest.(check bool) "unknown alias mutation invalidates" false
        (Init_link.ready (Init_link.invalidate_root state "local:1") ~full:false a "cursor");
      Alcotest.(check bool) "full storage needs no head premise" true
        (Init_link.ready Init_link.empty ~full:true b "arbitrary"));
  Alcotest.test_case "Field invalidation distinguishes head values from stored links" `Quick
    (fun () ->
      let storage = ("L0", ["core"; "next"]) in
      let state = Init_link.establish Init_link.empty storage "L0:.core.head" in
      let state = Init_link.copy state ~target:"L1:" ~source:"L0:.core.head" in
      let ready st value = Init_link.ready st ~full:false storage value in
      Alcotest.(check bool) "metadata preserves the head" true
        (ready (Init_link.invalidate_path state ("L0", ["count"])) "L0:.core.head");
      let changed_head = Init_link.invalidate_path state ("L0", ["core"; "head"]) in
      Alcotest.(check bool) "overwritten head is forgotten" false (ready changed_head "L0:.core.head");
      Alcotest.(check bool) "old scalar copy survives" true (ready changed_head "L1:");
      Alcotest.(check bool) "array write invalidates every predecessor" false
        (ready (Init_link.invalidate_path state storage) "L1:");
      Alcotest.(check bool) "parent overwrite includes descendants" false
        (ready (Init_link.invalidate_path state ("L0", ["core"])) "L1:"));
]

let () = Alcotest.run "init-link" ["certificates", tests]
