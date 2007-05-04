module type IN = sig
  val identifier : string
  val title : string
  val descr : string
  val moderated : bool
  val readable_by : Users.user
  val writable_by : Users.user
  val moderators : Users.user
  val url : string list
  val exit_link : Eliom.server_params -> [> Xhtmltypes.a ] XHTML.M.elt
  val mk_log_form :
    Eliom.server_params ->
    Users.user option -> [> Xhtmltypes.form ] XHTML.M.elt
  val max_rows : int32
end

module type OUT = sig
  val srv_forum :
    (unit, unit,
     [> `Attached of [> `Internal of [> `Service ] * [> `Get ] ] Eliom.a_s ],
     [ `WithoutSuffix ], unit Eliom.param_name, unit Eliom.param_name,
     [> `Registrable ])
    Eliom.service
  val login_actions : Eliom.server_params -> Users.user option -> unit
  val logout_actions : Eliom.server_params -> unit
end

module Make :  functor (A : IN) -> OUT
