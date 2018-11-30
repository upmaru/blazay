defmodule Upstream.Worker.Base do
  @moduledoc """
  Simple Worker for single threaded uploading
  """
  defmacro __using__(_) do
    quote do
      use GenServer

      @upload_timeout Application.get_env(:upstream, :upload)[:timeout] || 20_000

      @behaviour unquote(__MODULE__)

      alias Upstream.Job
      alias Upstream.B2.Upload

      alias Upstream.Uploader.{
        TaskSupervisor,
        Checksum,
        Flow
      }

      alias Upstream.B2.Account

      require Logger

      # Client API

      def start_link(job) do
        GenServer.start_link(__MODULE__, job)
      end

      def upload(pid) do
        GenServer.call(pid, :upload, @upload_timeout)
      end

      # Server Callbacks

      def init(job) do
        Job.State.start(job)

        {:ok, handle_setup(%{job: job, uid: job.uid, current_state: :started})}
      end

      def handle_call(:upload, _from, state) do
        authorization = Account.authorization()

        case task(authorization, state) do
          {:ok, result} ->
            Job.complete(state, result)

            {:stop, :normal, {:ok, result},
             Map.merge(state, %{
               current_state: :uploaded
             })}

          {:error, reason} ->
            Job.error(state, reason)

            {:stop, {:error, reason}, {:error, reason},
             Map.merge(state, %{
               current_state: :upload_failed
             })}
        end
      end

      def terminate(reason, state) do
        handle_stop(state)

        cond do
          Job.State.completed?(state) ->
            Logger.info("[Upstream] Completed #{state.uid.name}")

          Job.State.errored?(state) ->
            Logger.info("[Upstream] Errored #{state.uid.name}")

          true ->
            Job.State.error(state, %{error: reason})
        end

        reason
      end

      # Private functions

      defp handle_stop(state), do: nil
      defp handle_setup(state), do: state

      defoverridable handle_stop: 1, handle_setup: 1
    end
  end

  @callback task(struct, map) :: {:ok, any} | {:error, any}
end
