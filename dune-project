(lang dune 2.9)
(name async-eio-lwt-chimera)
(formatting disabled)
(generate_opam_files true)
(source (github talex5/async-eio-lwt-chimera))
(authors "Thomas Leonard")
(maintainers "talex5@gmail.com")
(package
 (name async-eio-lwt-chimera)
 (synopsis "Demo using Async, Eio and Lwt together")
 (depends
  async_eio
  eio_main))
(using mdx 0.1)
