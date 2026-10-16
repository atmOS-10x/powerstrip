defmodule Electric.Plug.MultiDatabaseRouter do
  @moduledoc """
  The HTTP API with `ELECTRIC_MULTI_DATABASE`: `/db/<name>/…` goes to the stack of database `<name>`
  (`Electric.MultiDatabase`), every other path to the default stack, both through `Electric.Plug.Router`.
  `DELETE /db/<name>` stops that stack and drops its slot, for example before the database is dropped.
  """
  @behaviour Plug

  alias Electric.MultiDatabase
  alias Electric.Plug.Router

  @impl true
  def init(default_opts), do: Router.init(default_opts)

  @impl true
  def call(%Plug.Conn{method: "DELETE", path_info: ["db", name]} = conn, default_opts) do
    conn = Plug.Conn.fetch_query_params(conn)

    cond do
      default_opts[:secret] not in [nil, conn.query_params["secret"]] ->
        conn |> Plug.Conn.send_resp(401, "Unauthorized") |> Plug.Conn.halt()

      MultiDatabase.valid_name?(name) and not MultiDatabase.default?(name) ->
        MultiDatabase.stop(name)
        conn |> Plug.Conn.send_resp(204, "") |> Plug.Conn.halt()

      true ->
        conn |> Plug.Conn.send_resp(404, "Not found") |> Plug.Conn.halt()
    end
  end

  def call(%Plug.Conn{path_info: ["db", name | rest]} = conn, default_opts) do
    cond do
      not MultiDatabase.valid_name?(name) ->
        conn |> Plug.Conn.send_resp(404, "Not found") |> Plug.Conn.halt()

      MultiDatabase.default?(name) ->
        Plug.forward(conn, rest, Router, default_opts)

      true ->
        Plug.forward(conn, rest, Router, MultiDatabase.router_opts(name))
    end
  end

  def call(conn, default_opts), do: Router.call(conn, default_opts)
end
