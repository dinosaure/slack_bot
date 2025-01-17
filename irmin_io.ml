open Lwt.Infix
open Lwt.Syntax
module Store = Irmin_mirage_git.Mem.KV.Make (Irmin.Contents.String)
module Sync = Irmin.Sync.Make (Store)

let connect_store ~git_ctx =
  print_endline "in connect";
  let config = Irmin_git.config "." in
  let remote, branch =
    match String.split_on_char '#' (Key_gen.remote ()) with
    | [ remote; branch ] -> (remote, branch)
    | _ -> (Key_gen.remote (), "main")
  in
  Store.Repo.v config >>= fun repository ->
  Store.of_branch repository branch >>= fun active_branch ->
  Lwt.return (active_branch, Store.remote ~ctx:git_ctx remote)

let pull active_branch remote =
  (* TODO(engil): Ask Romain why `Set??? *)
  Sync.pull active_branch remote `Set >>= function
  | Error err -> Fmt.failwith "%a" Sync.pp_pull_error err
  | Ok (`Empty | `Head _) -> Lwt.return ()

let push active_branch remote =
  Sync.push active_branch remote >>= function
  | Ok `Empty ->
      print_endline "Pushing to upstream irmin was possibly useless.";
      Lwt.return_ok ()
  | Ok (`Head _commit1) ->
      print_endline "Pushed something probably useful to upstream irmin";
      Lwt.return_ok ()
  | Error err -> Lwt.return_error (Rresult.R.msgf "%a" Sync.pp_push_error err)

let info message () =
  Store.Info.v ~author:"Sonja Heinze & Gargi Sharma & Enguerrand Decorne"
    ~message 0L

type matches = { matched : string list list } [@@deriving yojson]
type timestamp = string

let get_old_matches db_path =
  let git_config = Irmin_git.config ~bare:true db_path in
  let* epoch_list =
    Store.Repo.v git_config >>= Store.main >>= fun t ->
    (* todo: also handle the case of directories with an error message*)
    Store.list t [ "matches" ] >|= List.map (fun (step, _) -> step)
  in
  let* matches =
    Store.Repo.v git_config >>= Store.main >>= fun t ->
    Lwt_list.map_s (fun epoch -> Store.get t [ "matches"; epoch ]) epoch_list
  in
  Lwt.return (List.combine epoch_list matches)

let write_matches_to_irmin ~git_ctx ~get_current_time our_match db_path =
  let git_config = Irmin_git.config ~bare:true db_path in
  let yojson_string_to_print =
    Yojson.Safe.to_string (matches_to_yojson { matched = our_match })
  in
  let current_time = get_current_time () in
  let (year, month, day), _ = Ptime.to_date_time current_time in
  let message = Printf.sprintf "Matches %i/%i/%i" day month year in
  Store.Repo.v git_config >>= Store.main >>= fun t ->
  let current_time_s = Ptime.to_rfc3339 current_time in
  let* () =
    Store.set_exn t
      [ "matches"; current_time_s ]
      yojson_string_to_print ~info:(info message)
  in
  let* active_branch, remote = connect_store ~git_ctx in
  push active_branch remote

let write_timestamp_to_irmin timestamp db_path =
  let git_config = Irmin_git.config ~bare:true db_path in
  let message = "last opt-in message's timestamp" in
  Store.Repo.v git_config >>= Store.main >>= fun t ->
  Store.set_exn t [ "last_timestamp" ] timestamp ~info:(info message)

let read_timestamp_from_irmin db_path =
  let git_config = Irmin_git.config ~bare:true db_path in
  Store.Repo.v git_config >>= Store.main >>= fun t ->
  Store.get t [ "last_timestamp" ]
