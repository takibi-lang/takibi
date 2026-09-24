(lang dune 3.17)
(using menhir 3.0)
(name takibi)

(generate_opam_files true)

(source
 (github takibi-lang/takibi))

(authors "Kiwamu Okabe <kiwamu@metasepi.org>")

(maintainers "Kiwamu Okabe <kiwamu@metasepi.org>")

(license LICENSE)

(documentation https://github.com/takibi-lang/takibi/blob/main/README.md)

(package
 (name takibi)
 (version 0.1.0)
 (synopsis "Takibi Language")
 (description "Takibi Language")
 (depends
  (ocaml (>= 5.4.0))
  (llvm (= 19-static))
  dune-build-info
  menhir
  ppx_deriving
  (alcotest :with-test)
  (bisect_ppx_ng :dev))
 (tags
  ("language" "compiler")))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
