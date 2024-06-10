module type Config = sig
  val num_harts : int
  val include_io_controller : Io_controller_config.t
end

module type Memory_config = sig
  val num_bytes : int
end
