val download : url:string -> destination:string -> (unit, string) result
(** Download an HTTPS archive to an existing, privately staged file. HTTPS
    applies to redirects and the streamed response cannot exceed 64 MiB. *)
