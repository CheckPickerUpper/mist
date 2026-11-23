import exception
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/function
import gleam/http/response
import gleam/string
import glisten
import glisten/socket.{type Socket, type SocketReason, Closed, Econnrefused}
import glisten/socket/options
import glisten/tcp
import mist

pub fn stopping_accepts_preserves_an_in_flight_response_test() {
  let listening = process.new_subject()
  let entered = process.new_subject()
  let assert Ok(server) =
    mist.new(fn(_request) {
      let release = process.new_subject()
      process.send(entered, release)
      let assert Ok(Nil) = process.receive(release, within: 1000)
      response.new(200)
      |> response.set_header("connection", "close")
      |> response.set_body(mist.Bytes(bytes_tree.from_string("ready")))
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _address) {
      process.send(listening, port)
    })
    |> mist.start_with_listener
  let assert Ok(port) = process.receive(listening, within: 1000)
  let assert Ok(client) = connect(port)

  let outcome =
    exception.rescue(fn() {
      let assert Ok(Nil) =
        tcp.send(
          client,
          bytes_tree.from_string(
            "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
          ),
        )
      let assert Ok(release) = process.receive(entered, within: 1000)

      let assert Ok(glisten.TcpServerInfo(port: stopped_port, ..)) =
        mist.stop_accepting(server.listener, within: 1000)
      assert stopped_port == port
      let assert Error(Econnrefused) = connect(port)

      process.send(release, Nil)
      let assert Ok(reply) = receive_response(client, <<>>)
      let assert Ok(reply) = bit_array.to_string(reply)
      assert string.starts_with(reply, "HTTP/1.1 200 ")
      let assert Ok(#(_headers, "ready")) = string.split_once(reply, "\r\n\r\n")
      Nil
    })

  let assert Ok(Nil) = tcp.close(client)
  let pid = server.started.pid
  let monitor = process.monitor(pid)
  process.unlink(pid)
  process.send_exit(pid)
  let assert Ok(process.ProcessDown(pid: stopped_pid, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, function.identity)
    |> process.selector_receive(within: 1000)
  assert stopped_pid == pid
  let assert Ok(Nil) = outcome
  Nil
}

fn connect(port: Int) -> Result(Socket, SocketReason) {
  do_connect(
    #(127, 0, 0, 1),
    port,
    options.to_erl_options([
      options.Mode(options.Binary),
      options.ActiveMode(options.Passive),
    ]),
    1000,
  )
}

@external(erlang, "gen_tcp", "connect")
fn do_connect(
  address: #(Int, Int, Int, Int),
  port: Int,
  options: List(options.ErlangTcpOption),
  timeout: Int,
) -> Result(Socket, SocketReason)

fn receive_response(
  socket: Socket,
  received: BitArray,
) -> Result(BitArray, SocketReason) {
  case tcp.receive_timeout(socket, 0, 1000) {
    Ok(data) -> receive_response(socket, <<received:bits, data:bits>>)
    Error(Closed) -> Ok(received)
    Error(reason) -> Error(reason)
  }
}
