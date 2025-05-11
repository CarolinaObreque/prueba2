defmodule Prueba2.ApiRouter do
  use Plug.Router
  require Logger
  import IO.ANSI

  @notification_color bright() <> cyan()
  @dice_color magenta()
  @reset reset()

  # Quitamos Plug.Logger para eliminar los mensajes de solicitudes HTTP
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  # Función de utilidad para formato de mensajes
  def format_turn_message(team_name, dice_value, old_position, new_position, username) do
    "#{@dice_color}[TURNO] #{username} del equipo #{team_name} tiró #{dice_value} y avanzó de #{old_position} a #{new_position}#{@reset}"
  end

  # Función para enviar mensajes de juego a peers
  defp send_game_message_to_peer(username, message, distribute) do
    Prueba2.P2PNetwork.get_peers()
    |> Enum.find(fn {_, name} -> name == username end)
    |> case do
      {address, _} ->
        Task.start(fn ->
          url = "http://#{address}/api/game-message"
          payload = %{
            message: message,
            source_username: Application.get_env(:prueba2, :username),
            distribute: distribute
          }
          try do
            HTTPoison.post!(url, Jason.encode!(payload),
              [{"Content-Type", "application/json"}], [timeout: 5_000])
          rescue
            _ -> Prueba2.P2PNetwork.remove_peer_by_username(username)
          end
        end)
      nil -> nil
    end
  end

  post "/api/dice-roll" do
    %{"value" => value, "username" => username} = conn.body_params
    IO.puts(@dice_color <> "#{username} tiró un dado y obtuvo: " <> bright() <> to_string(value) <> @reset)
    send_resp(conn, 200, "OK")
  end

  post "/api/join-network" do
    %{"address" => requester_address, "username" => requester_username} = conn.body_params
    password_hash = Map.get(conn.body_params, "password_hash")

    # Verificar si el nombre de usuario es muy largo
    max_length = Application.get_env(:prueba2, :max_alias_length, 15)
    my_username = Application.get_env(:prueba2, :username)

    cond do
      # Verificar la contraseña primero
      not Prueba2.P2PNetwork.verify_password(password_hash) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{
          status: "error",
          message: "Contraseña incorrecta"
        }))

      # Verificar longitud máxima
      String.length(requester_username) > max_length ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{
          status: "error",
          message: "Nombre de usuario demasiado largo (máximo #{max_length} caracteres)"
        }))

      # Verificar nombre vacío
      String.length(requester_username) == 0 ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{
          status: "error",
          message: "El nombre de usuario no puede estar vacío"
        }))

      # Verificar si coincide con el nombre del host
      requester_username == my_username ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(409, Jason.encode!(%{
          status: "error",
          message: "El nombre de usuario ya está en uso"
        }))

      # Verificar si ya existe en la red
      Prueba2.P2PNetwork.username_exists?(requester_username) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(409, Jason.encode!(%{
          status: "error",
          message: "El nombre de usuario ya está en uso"
        }))

      # Si todo está en orden, añadir al peer
      true ->
        Prueba2.P2PNetwork.add_peer(requester_address, requester_username)

        # Obtenemos los peers para enviar al nuevo miembro
        peers_list = Prueba2.P2PNetwork.get_peers()
                    |> Enum.reject(fn {addr, _} -> addr == requester_address end)
                    |> Enum.map(fn {addr, name} -> %{address: addr, username: name} end)

        # Obtenemos la información de equipos para enviar al nuevo miembro
        teams_data = Prueba2.TeamManager.get_teams()

        # Ensure teams_data is always a map, even if it somehow got converted to a list
        teams_data_map = cond do
          is_map(teams_data) -> teams_data
          is_list(teams_data) -> Enum.into(teams_data, %{})
          true -> %{}
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{
          status: "success",
          peers: peers_list,
          host_username: my_username,
          teams: teams_data_map
        }))
    end
  end

  post "/api/new-peer" do
    %{"peer" => %{"address" => new_address, "username" => new_username}, "from_username" => _notifier_username} = conn.body_params

    # Verificar si el nombre ya existe antes de añadirlo
    if Prueba2.P2PNetwork.username_exists?(new_username) do
      # Silenciar mensajes de error
    else
      # Mostrar un mensaje más sencillo solo cuando un peer se une
      IO.puts(@notification_color <> "#{new_username} se unió a la red" <> @reset)
      Prueba2.P2PNetwork.add_peer(new_address, new_username)
    end

    send_resp(conn, 200, "OK")
  end

  post "/api/peer-exit" do
    %{"peer" => exiting_peer, "username" => exiting_username} = conn.body_params
    # Mostrar un mensaje sencillo cuando un peer se va
    IO.puts(@notification_color <> "#{exiting_username} salió de la red" <> @reset)
    Prueba2.P2PNetwork.remove_peer(exiting_peer)
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  post "/api/team-membership-update" do
    %{"player_name" => player_name, "team_name" => team_name} = conn.body_params

    # Actualizar registro local de membresía (usando la nueva API)
    Prueba2.TeamManager.join_team(player_name, team_name)

    # Actualizar la información del peer si se trata de un usuario local
    try do
      Process.send_after(Prueba2.P2PNetwork, {:update_player_team, player_name, team_name}, 100)
    rescue
      _ -> nil # Silenciar errores
    end

    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  post "/api/team-ready-update" do
    %{"team_name" => team_name} = conn.body_params

    # Check if this is a source-initiated update to prevent broadcast loops
    source_initiated = Map.get(conn.body_params, "source_initiated", false)
    source_username = Map.get(conn.body_params, "source_username", "unknown")

    # Log who initiated the team ready status
    if source_initiated do
      IO.puts(@notification_color <> "#{source_username} marcó al equipo #{team_name} como listo" <> @reset)
    end

    # Actualizar estado del equipo localmente sin rebroadcast
    GenServer.call(Prueba2.TeamManager, {:set_team_ready_no_broadcast, team_name})

    # Intentar iniciar el juego si todos los equipos están listos
    if Prueba2.TeamManager.all_teams_ready?() do
      Prueba2.ShiftManager.start_game()
    end

    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  post "/api/message" do
    %{"message" => message, "from" => from_username} = conn.body_params

    cond do
      String.starts_with?(message, "TEAM_EVENT: ") ->
        # Es un evento de equipo, lo mostramos con formato especial
        team_message = String.replace_prefix(message, "TEAM_EVENT: ", "")
        # Mantener los mensajes de equipo para mejor experiencia de usuario
        IO.puts(cyan() <> "[EQUIPO] " <> reset() <> team_message)

      String.starts_with?(message, "GAME_OVER: ") ->
        # Mensaje de fin de juego - asegurarse de que todos los nodos lo reconozcan
        game_over_message = String.replace_prefix(message, "GAME_OVER: ", "")
        IO.puts(bright() <> magenta() <> "[JUEGO TERMINADO] " <> reset() <> game_over_message)

        # Utilizar try-catch para manejar posibles errores si los procesos ya no existen
        try do
          # Asegurarse de que el juego se marque como terminado localmente
          if Process.whereis(Prueba2.ShiftManager) do
            Process.send(Prueba2.ShiftManager, :game_over, [])
          end

          # Detener procesos de sincronización si aún están vivos
          if Process.whereis(Prueba2.TeamPositionSync) do
            GenServer.cast(Prueba2.TeamPositionSync, :stop_sync)
          end

          # Enviar mensaje a la interfaz de usuario para volver al menú principal
          if Process.whereis(Prueba2.UserInterface) do
            Process.send(Prueba2.UserInterface, :game_over, [])
          end
        rescue
          _ -> IO.puts(red() <> "[ERROR] Problema al manejar fin de juego, probablemente algunos procesos ya terminaron" <> reset())
        end

      true ->
        # Solo mostrar mensajes importantes o de jugadas
        if String.contains?(message, ["jugó", "ganó", "avanzó", "posición", "terminó"]) do
          IO.puts(bright() <> "#{from_username}: " <> reset() <> message)
        end
        # Eliminamos logs de otros mensajes menos importantes
    end

    send_resp(conn, 200, "OK")
  end

  get "/api/get-teams" do
    # Obtener todos los equipos y enviarlos como respuesta
    teams = Prueba2.TeamManager.get_teams()

    # Ensure teams is always a map
    teams_map = cond do
      is_map(teams) -> teams
      is_list(teams) -> Enum.into(teams, %{})
      true -> %{}
    end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{
      status: "success",
      teams: teams_map
    }))
  end

  # Obtener el estado actual del juego
  get "/api/game-state" do
    # Obtener el estado del juego
    case Prueba2.GameManager.get_game_state() do
      {:ok, game_state} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{
          status: "success",
          game_state: game_state
        }))
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(500, Jason.encode!(%{
          status: "error",
          message: "Error al obtener el estado del juego"
        }))
    end
  end

  # Actualización de posición de equipo
  post "/api/position-update" do
    %{"team_name" => team_name, "position" => position, "source_username" => source_username} = conn.body_params
    distribute = Map.get(conn.body_params, "distribute", false)

    # Actualizar la posición del equipo en TeamManager sin hacer broadcast recursivo
    case Prueba2.TeamManager.get_team_position(team_name) do
      {:ok, current_position} ->
        if position > current_position do
          # Solo actualizar si la nueva posición es mayor que la actual
          GenServer.call(Prueba2.TeamManager, {:update_team_position_sync, team_name, position})

          # Si debemos distribuir, enviar a todos los miembros de nuestro equipo
          if distribute do
            Prueba2.TeamPositionSync.distribute_to_team(team_name, position, source_username)
          end

          # Verificar si es posición ganadora
          if position >= 100 do
            # Notificar localmente que este equipo ha ganado
            Process.send_after(Prueba2.ShiftManager, {:check_win, team_name}, 100)
          end
        end
      _ -> nil
    end

    send_resp(conn, 200, "OK")
  end

  # Nuevo endpoint para actualizaciones de turno específicas del equipo
  post "/api/turn-update" do
    %{
      "team" => team_name,
      "dice_value" => dice_value,
      "old_position" => old_position,
      "new_position" => new_position,
      "message" => message,
      "is_winner" => is_winner,
      "source_username" => source_username
    } = conn.body_params

    # Actualizar la posición localmente sin hacer broadcast
    GenServer.call(Prueba2.TeamManager, {:update_team_position_sync, team_name, new_position})

    # Mostrar mensaje en la consola local
    IO.puts(Prueba2.ApiRouter.format_turn_message(team_name, dice_value, old_position, new_position, source_username))

    # Si es ganador, verificar localmente
    if is_winner do
      Process.send_after(Prueba2.ShiftManager, {:check_win, team_name}, 100)
    end

    send_resp(conn, 200, "OK")
  end

  # Endpoint para mensajes de juego distribuidos
  post "/api/game-message" do
    %{"message" => message, "source_username" => source_username} = conn.body_params
    distribute = Map.get(conn.body_params, "distribute", false)

    # Mostrar mensaje localmente
    IO.puts(bright() <> cyan() <> "[JUEGO] " <> reset() <> message)

    # Verificar si es un mensaje de fin de juego antes de intentar distribuirlo
    is_game_over = String.contains?(message, "ha ganado") || String.contains?(message, "juego ha terminado")

    # Si necesitamos distribuir a nuestro equipo y NO es un mensaje de fin de juego
    if distribute && !is_game_over do
      # Obtener equipos para distribuir a nuestro propio equipo
      try do
        teams = Prueba2.TeamManager.get_teams()
        current_username = Application.get_env(:prueba2, :username)

        # Encontrar nuestro equipo
        current_team = Enum.find_value(teams, fn {team_name, team_data} ->
          if current_username in team_data.players, do: team_name, else: nil
        end)

        if current_team do
          team_info = teams[current_team]

          # Enviar a todos los miembros de nuestro equipo excepto a nosotros
          team_info.players
          |> Enum.filter(fn player -> player != current_username end)
          |> Enum.each(fn member ->
            send_game_message_to_peer(member, message, false)
          end)
        end
      rescue
        error ->
          # Si hay un error al obtener los equipos, registrarlo pero no fallar
          IO.puts(red() <> "[ERROR] No se pudieron obtener los equipos: #{inspect(error)}" <> reset())
      end
    end

    send_resp(conn, 200, "OK")
  end

  match _ do
    send_resp(conn, 404, "Ruta no encontrada")
  end
end
