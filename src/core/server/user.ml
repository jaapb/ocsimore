(* Ocsimore
 * Copyright (C) 2005
 * Laboratoire PPS - Université Paris Diderot - CNRS
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(**
User management

@author Jaap Boender
@author Piero Furiesi
@author Vincent Balat
*)

open Eliom_lib
open Lwt_ops
open User_sql.Types
open Ocsimore_lib

exception ConnectionRefused
exception BadPassword
exception BadUser
exception UnknownUser of string
exception UseAuth of userid


(* YYY not really sure that all User_sql functions that transforms a
   string/id into a user properly return NotAnUser when they fail.
   Thus we still catch Not_found, just in case... *)


(* We might want to simply overwrite incorrect values by the correct ones *)
let possibly_create ~login ~fullname ?email ?pwd () =
  Lwt_main.run (
    try_lwt
      User_sql.get_basicuser_by_login login
    with User_sql.NotAnUser | Not_found ->
       let email = match email with
         | None -> None
         | Some f -> f ()
       and password = match pwd with
         | None -> Connect_forbidden
         | Some f -> f ()
       in
       fst =|< User_sql.new_user
                 ~name:login
                 ~password
                 ~fullname
                 ~email
                 ~dyn:false
  )


let anonymous_login="anonymous"
let anonymous = possibly_create ~login:anonymous_login ~fullname:"Anonymous" ()
let anonymous' = basic_user anonymous
let nobody_login = "nobody"
let nobody = possibly_create ~login:nobody_login ~fullname:"Nobody" ()
let nobody' = basic_user nobody

let admin_login="admin"
let admin =
  let rec get_pwd message =
    print_string message;
    flush Pervasives.stdout;
    match (try
             let default = Unix.tcgetattr Unix.stdin in
             let silent = {default with
                             Unix.c_echo = false;
                             Unix.c_echoe = false;
                             Unix.c_echok = false;
                             Unix.c_echonl = false}
             in Some (default, silent)
           with _ -> None)
    with
      | Some (default, silent) ->
          Unix.tcsetattr Unix.stdin Unix.TCSANOW silent;
          (try
             let s = input_line Pervasives.stdin
             in Unix.tcsetattr Unix.stdin Unix.TCSANOW default; s
           with x ->
             Unix.tcsetattr Unix.stdin Unix.TCSANOW default; raise x)
      | None ->  input_line Pervasives.stdin

  and ask_pwd () =
    let pwd1 = get_pwd "Please enter a password for admin: "
    and pwd2 = get_pwd "\nPlease enter the same password again: " in
      if pwd1 = pwd2
      then (print_endline "\nNew password registered.";
            User_sql.Types.Ocsimore_user_safe (Bcrypt.hash pwd1))
      else (print_endline "\nPasswords do not match, please try again."; ask_pwd ())

  and ask_email () =
    print_endline "\nEnter a valid e-mail address for admin: ";
    let email = input_line Pervasives.stdin in
      print_endline ("\n'" ^ email ^ "': Confirm this address? (Y/N)");
      match input_line Pervasives.stdin with
        | "Y"|"y" -> print_endline "\n Thank you."; Some email
        | _ -> print_endline "\n"; ask_email()
  in
  possibly_create ~login:admin_login ~fullname:"Admin"
    ~pwd:ask_pwd ~email:ask_email ()

let admin' = basic_user admin


let param_user = {
  param_description = "login of the user";
  param_get = User_sql.get_users_login;
  param_display = Some
    (fun uid ->
       User_sql.get_basicuser_data (userid_from_sql uid) >>= fun r ->
       Lwt.return (Printf.sprintf "'%s' (%s)" r.user_login r.user_fullname));
  find_param_functions =
    Some ((fun uname ->
             User_sql.get_basicuser_by_login uname >>= fun u ->
             Lwt.return (sql_from_userid u)),
          (fun uid ->
             User_sql.userid_to_string (userid_from_sql uid))
         );
}

let group_can_create_groups =
  Lwt_main.run
    (User_sql.new_nonparameterized_group ~prefix:"users"
       ~name:"can_create_groups"
       ~descr:"can create new groups"
    )

let group_can_admin_group : [`User] parameterized_group =
  Lwt_main.run
    (User_sql.new_parameterized_group ~prefix:"users"
       ~name:"can_admin_group"
       ~descr:"can add or remove people in the group"
       ~find_param:param_user
    )

let group_can_create_users =
  Lwt_main.run
    (User_sql.new_nonparameterized_group ~prefix:"users" ~name:"GroupsCreators"
       ~descr:"can create new Ocsimore users")

let group_can_admin_users =
  Lwt_main.run
    (User_sql.new_nonparameterized_group ~prefix:"users"
       ~name:"admin"
       ~descr:"can admin users"
    )




let get_basicuser_by_login login =
  try_lwt
    User_sql.get_basicuser_by_login login
  with | Not_found | User_sql.NotAnUser ->
    Lwt.return nobody

let get_user_by_name name =
  try_lwt
    User_sql.get_user_by_name name
  with | Not_found | User_sql.NotAnUser -> Lwt.return nobody'


let user_list_of_string s =
  let f beg a =
    lwt beg = beg in
    try_lwt
       lwt v = User_sql.get_user_by_name a in
       if v = nobody'
       then Lwt.return beg
       else Lwt.return (v::beg)
    with | User_sql.NotAnUser -> Lwt.fail (UnknownUser a)
  in
  let r = Eliom_lib.String.split '\n' s in
  List.fold_left f (Lwt.return []) r


(* dynamic groups: *)
module DynGroups = Hashtbl.Make(
  struct
    type t = user
    let equal a a' = a = a'
    let hash = Hashtbl.hash
  end)

let add_dyn_group, fold_dyn_groups =
  let table = DynGroups.create 5 in
  DynGroups.add table,
  (fun f -> DynGroups.fold f table)


let ok_name name =
  try ignore (String.index name '#'); false
  with Not_found -> true

let create_user, create_fresh_user =
  let mutex_user = Lwt_mutex.create () in
  let aux already_existing ~name ~pwd ~fullname ?email ?test () =
    if ok_name name = false then
      Lwt.fail BadUser
    else
      lwt () = Lwt_mutex.lock mutex_user in
      lwt u = get_basicuser_by_login name in
      lwt u =
        if (u = nobody) && (name != nobody_login)
        then (* the user does not exist *)
          let dyn = not (test = None) in
          fst =|< User_sql.new_user ~name ~password:pwd ~fullname ~email ~dyn
        else
          already_existing u
      in
      iter_option (add_dyn_group (basic_user u)) test;
      Lwt_mutex.unlock mutex_user;
      Lwt.return u
  in
  aux (fun u -> Lwt.return u),
  aux (fun _ -> raise BadUser) ?test:None

let create_external_user name =
  create_user ~name
    ~pwd:User_sql.Types.External_Auth
    ~fullname:name
    ~email:(name ^ "@localhost")
    ()

let authenticate ~name ~pwd =
  lwt u = get_basicuser_by_login name in
  if u = nobody
  then Lwt.fail BadUser
  else
    lwt u = User_sql.get_basicuser_data u in
    match u.user_pwd with
      | User_sql.Types.External_Auth -> Lwt.fail (UseAuth u.user_id)
      | Ocsimore_user_plain p ->
          if p = pwd then Lwt.return u else Lwt.fail BadPassword
      | Ocsimore_user_crypt h ->
          lwt ok = Crypt.check_passwd ~passwd:pwd ~hash:h in
          if ok then Lwt.return u else Lwt.fail BadPassword
      | Ocsimore_user_safe h ->
          let ok = Bcrypt.verify pwd h in
          if ok then Lwt.return u else Lwt.fail BadPassword
      | Connect_forbidden ->
          Lwt.fail BadPassword


(** {2 Session data} *)

let user_ref =
  Eliom_reference.eref
    ~scope:Eliom_common.default_session_scope
    ~persistent:"ocsimore_user_table_v2"
    None

let get_user_ () =
  Eliom_reference.get user_ref >>= function
    | None ->
        Lwt.return anonymous
    | Some u ->
        try_lwt
          lwt _ = User_sql.get_basicuser_data u in
          Lwt.return u
        with | User_sql.NotAnUser | Not_found ->
          lwt () =
            Eliom_state.discard ~scope:Eliom_common.default_session_scope ()
          in
          lwt () = Eliom_state.discard ~scope:Eliom_common.request_scope () in
          Lwt.return anonymous

let user_request_cache =
  Eliom_reference.eref_from_fun ~scope:Eliom_common.request_scope get_user_

let get_user_sd () =
  Eliom_reference.get user_request_cache >>= fun x -> x

let get_user_id () =
  get_user_sd ()

let get_user_data () =
  get_user_sd () >>= User_sql.get_basicuser_data

let get_user_name () =
  get_user_data () >|= function { user_login; _ } -> user_login

let groups_table_request_cache =
  Eliom_reference.eref_from_fun
    ~scope:Eliom_common.request_scope
    (fun () -> Hashtbl.create 37)

let in_group_ ~user ~group () =
  let no_sp = Eliom_common.get_sp_option () = None in
  lwt get_in_cache, update_cache =
    if no_sp then
      Lwt.return ((fun _ -> raise Not_found), (fun _ _ -> ()))
    else
      lwt table = Eliom_reference.get groups_table_request_cache in
      Lwt.return (Hashtbl.find table, Hashtbl.add table)
  in
  let return u g v =
    update_cache (u, g) v; Lwt.return v
  in
  let rec aux2 g = function
    | [] -> Lwt.return false
    | g2::l ->
        aux g2 g >>= function
          | true -> return g2 g true
          | false -> aux2 g l
  and aux u g =
(*    User_sql.user_to_string u >>= fun su ->
    User_sql.user_to_string g >>= fun sg ->
    Lwt_log.ign_error_f ~section "Is %s in %s?" su sg; *)
    try Lwt.return (get_in_cache (u, g))
    with Not_found ->
      lwt gl = User_sql.groups_of_user ~user:u in
      if List.mem g gl
      then return u g true
      else aux2 g gl
  in
  if (user = nobody') || (group = nobody')
  then Lwt.return false
  else
    if (user = group) || (user = admin')
    then Lwt.return true
    else aux user group >>= function
      | true ->
          return user group true
      | false ->
          if no_sp then
            return user group false
          else
            lwt user' = get_user_id () in
              if user = basic_user user' then
                lwt r =
                  fold_dyn_groups
                    (fun k f b ->
                       b >>= function
                         | true -> Lwt.return true
                         | false ->
                             f () >>= function
                               | false -> Lwt.return false
                               | true ->
                                   if k = group then
                                     Lwt.return true
                                   else
                                     aux k group)
                    (Lwt.return false)
                  in
                  return user group r
              else
                return user group false


let add_to_group ~(user:user) ~(group:user) =
  lwt dy =
    User_sql.get_user_data group >|= fun { user_dyn; _ } -> user_dyn
  in
  if dy
  then
    lwt us = User_sql.user_to_string user in
    lwt gs = User_sql.user_to_string group in
    Lwt_log.ign_warning_f ~section
      "Not possible to insert user %s in group %s.\
       This group is dynamic (risk of loops). (ignoring)"
      us gs ;
    Lwt.return ()
  else
    if (user = nobody') || (group = nobody')
    then begin
    Lwt_log.ign_warning ~section
      "Not possible to insert user nobody into a group, or insert someone in group nobody. (ignoring)";
      Lwt.return ()
    end
    else
      in_group_ ~user:group ~group:user () >>= function
        | true ->
            lwt us = User_sql.user_to_string user in
            lwt gs = User_sql.user_to_string group in
            Lwt_log.ign_warning_f ~section
              "Circular group when inserting user %s in group %s. (ignoring)"
              us gs
            ;
            Lwt.return ()
        | false ->
            User_sql.add_to_group ~user ~group

(* XXX Should remove check that we do not remove from a dyn group *)
let remove_from_group = User_sql.remove_from_group


let add_to_groups ~user ~groups =
  Lwt_list.iter_s
    (fun group -> add_to_group ~user ~group)
    groups




let iter_list_group f ~l ~group =
  List.fold_left
    (fun beg u ->
       lwt () = beg in
       f ~user:u ~group)
    (Lwt.return ())
    l

let add_list_to_group = iter_list_group add_to_group
let remove_list_from_group = iter_list_group User_sql.remove_from_group



let is_logged_on () =
  get_user_sd () >|= fun u -> not ((u = anonymous) || (u = nobody))


(* This is a dynamic group that contains the currently logged user.
   It is almost entirely equivalent to a group that contains all the users,
   as only the users that are effectively able to logging can be inside.
*)
let authenticated_users =
  Lwt_main.run
    (lwt users =
       create_user ~name:"users" ~pwd:User_sql.Types.Connect_forbidden
         ~fullname:"Authenticated users" ~test:is_logged_on ()
     in
     lwt () = add_to_group ~user:(basic_user users) ~group:anonymous' in
     Lwt.return users
)


let is_external_user () =
  get_user_data () >|= fun u -> u.user_pwd = External_Auth


let _external_users =
  Lwt_main.run
    (create_user ~name:"external_users" ~pwd:User_sql.Types.Connect_forbidden
       ~fullname:"Users using external authentification"
       ~test:is_external_user ()
)


let set_session_data (user_id, username) =
  lwt () = Eliom_reference.set user_request_cache (Lwt.return user_id) in
  lwt () =
    Eliom_state.set_persistent_data_session_group
      ~scope:Eliom_common.default_session_scope
      ~set_max:(Some 2) username
  in
  (* We store the user_id inside Eliom. Alternatively, we could
     just use the session group (and not create a table inside Eliom
     at all), but we would just obtain a string, not an userid *)
  Eliom_reference.set user_ref (Some user_id)


let in_group ?user ~group () =
  lwt user =
    match user with
      | None -> get_user_id () >|= basic_user
      | Some user -> Lwt.return user
  in
  in_group_ ~user ~group ()


let user_from_userlogin_xform user =
  get_user_by_name user >|= fun u ->
    if u = basic_user nobody && user <> nobody_login then
      Xform.ConvError ("This user does not exists: " ^ user)
    else
      Xform.Converted u


module GenericRights = struct

  (* We need second-order polymorphism for the accessors on
     admin_writer_reader fields *)
  type admin_writer_reader_access =
      { field : 'a. 'a admin_writer_reader -> 'a parameterized_group }


  let grp_admin = { field = fun grp -> grp.grp_admin }
  let grp_write = { field = fun grp -> grp.grp_writer }
  let grp_read  = { field = fun grp -> grp.grp_reader }

  let map_awr f =
    f grp_admin,
    f grp_write,
    f grp_read


  let map_awr_lwt f =
    f grp_admin >>= fun a ->
    f grp_write >>= fun w ->
    f grp_read  >>= fun r ->
    Lwt.return (a, w, r)

  let iter_awr_lwt f =
    f grp_admin >>= fun () ->
    f grp_write >>= fun () ->
    f grp_read

  let admin_writer_reader_groups grps =
    (fun i -> apply_parameterized_group grps.grp_reader i),
    (fun i -> apply_parameterized_group grps.grp_writer i),
    (fun i -> apply_parameterized_group grps.grp_admin i)





  let create_admin_writer_reader ~prefix ~name ~descr ~find_param =
    let namea, namew, namer =
      (name ^ "Admin",
       name ^ "Writer",
       name ^ "Reader")
    and descra, descrw, descrr =
      ("can admin " ^ descr,
       "can write in " ^ descr,
       "can read " ^ descr)
    in
    let f = User_sql.new_parameterized_group ~prefix ~find_param in
    Lwt_main.run (
      lwt ga = f ~name:namea ~descr:descra in
      lwt gw = f ~name:namew ~descr:descrw in
      lwt gr = f ~name:namer ~descr:descrr in
      lwt () = User_sql.add_generic_inclusion ~subset:ga ~superset:gw in
      lwt () = User_sql.add_generic_inclusion ~subset:gw ~superset:gr in
      Lwt.return { grp_admin = ga; grp_writer = gw; grp_reader = gr }
    )

end
