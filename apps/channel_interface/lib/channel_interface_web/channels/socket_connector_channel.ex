defmodule ChannelInterfaceWeb.SocketConnectorChannel do
  use ChannelInterfaceWeb, :channel
  require Logger

  defmacro keypair_initiator, do: Application.get_env(:ae_socket_connector, :accounts)[:initiator]
  defmacro keypair_responder, do: Application.get_env(:ae_socket_connector, :accounts)[:responder]

  defmacro ae_url, do: Application.get_env(:ae_socket_connector, :node)[:ae_url]

  defmacro network_id, do: Application.get_env(:ae_socket_connector, :node)[:network_id]

  def sign_message_and_dispatch(pid_session_holder, method, to_sign) do
    signed = SessionHolder.sign_message(pid_session_holder, to_sign)
    fun = &SocketConnector.send_signed_message(&1, method, signed)
    SessionHolder.run_action(pid_session_holder, fun)
  end

  def start_session_holder(role, port, channel_id, keypair_initiator, keypair_responder, connection_callback_handler) when role in [:initiator, :responder] do
    name = {:via, Registry, {Registry.SessionHolder, role}}

    case Registry.lookup(Registry.SessionHolder, role) do
      [{pid, _}] ->
        Logger.info("Server already running, stopping #{inspect(pid)}")
        SessionHolder.close_connection(pid)
        Process.exit(pid, :kill)
      _ ->
        :ok
    end

    {pub_key, priv_key} =
      case role do
        :initiator -> keypair_initiator.()
        :responder -> keypair_responder.()
      end

    {initiator_pub_key, _responder_priv_key} = keypair_initiator.()
    {responder_pub_key, _responder_priv_key} = keypair_responder.()

    color =
      case role do
        :initiator -> :yellow
        :responder -> :blue
      end

    config = ClientRunner.custom_config(%{}, %{port: port})

    connect_map = %{
        socket_connector: %{
          pub_key: pub_key,
          session: config.(initiator_pub_key, responder_pub_key),
          role: role
        },
        log_config: %{file: Atom.to_string(role) <> "_" <> pub_key},
        ae_url: ae_url(),
        network_id: network_id(),
        priv_key: priv_key,
        connection_callbacks: connection_callback_handler,
        color: color,
        pid_name: name
      }
    {:ok, pid_session_holder} =
      case (channel_id == "") do
        true ->
          SessionHolder.start_link(connect_map)
        _ ->
          SessionHolder.start_link(Map.merge(connect_map, %{reestablish: %{channel_id: channel_id, port: port}}))
      end

    # {:ok, pid_session_holder} =
    # SessionHolder.start_link(connect_map)

    Process.unlink(pid_session_holder)
    Logger.info("Server not already running new pid is #{inspect(pid_session_holder)}")
    pid_session_holder
    # end
  end

  def join("socket_connector:lobby", payload, socket) do
    if authorized?(payload) do
      {:ok,
       Phoenix.Socket.assign(socket,
         role: String.to_atom(payload["role"])
       )}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Channels can be used in a request/response fashion
  # by sending replies to requests from the client
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  # It is also common to receive messages from the client and
  # broadcast to everyone in the current topic (socket_connector:lobby).
  def handle_in("shout", payload, socket) do
    socket.assigns.pid_session_holder
    push(socket, "shout", payload)
    {:noreply, socket}
  end

  # also covers reestablish
  def handle_in("connect", payload, socket) do
    pid_session_holder =
      start_session_holder(socket.assigns.role, String.to_integer(payload["port"]), payload["channel_id"], fn -> keypair_initiator() end, fn -> keypair_responder() end, ClientRunner.connection_callback(self(), "yellow"))

    {:noreply, assign(socket, :pid_session_holder, pid_session_holder)}
  end

  def handle_in(action, payload, socket) do
    socketholder_pid = socket.assigns.pid_session_holder

    case action do
      "leave" ->
        SessionHolder.leave(socketholder_pid)

      # "reestablish" ->
      #   SessionHolder.reestablish(socketholder_pid, String.to_integer(payload["port"]))

      "teardown" ->
        SessionHolder.close_connection(socketholder_pid)

      "shutdown" ->
        fun = &SocketConnector.shutdown(&1)
        SessionHolder.run_action(socketholder_pid, fun)

      "transfer" ->
        fun = &SocketConnector.initiate_transfer(&1, payload["amount"])
        SessionHolder.run_action(socketholder_pid, fun)

      "sign" ->
        sign_message_and_dispatch(socketholder_pid, payload["method"], payload["to_sign"])
    end

    {:noreply, socket}
  end

  # Add authorization logic here as required.
  defp authorized?(_payload) do
    true
  end

  def handle_cast({:connection_update, {status, _reason} = update}, socket) do
    Logger.info("Connection update, #{inspect update}")
    push(socket, "shout", %{message: inspect(update), name: "bot"})
    push(socket, Atom.to_string(status), %{})
    {:noreply, socket}
  end

  def handle_cast({:match_jobs, {:sign_approve, _round, method}, to_sign} = message, socket) do
    Logger.info("Sign request #{inspect(message)}")
    push(socket, "sign", %{message: inspect(message), method: method, to_sign: to_sign})
    push(socket, "shout", %{message: inspect(message), name: "bot"})
    # broadcast socket, "shout", %{message: inspect(message), name: "bot2"}
    {:noreply, socket}
  end

  def handle_cast(message, socket) do
    push(socket, "shout", %{message: inspect(message), name: "bot"})
    {:noreply, socket}
  end
end
