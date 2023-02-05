defmodule ElixirSense.Core.Normalized.Code do
  @moduledoc """
  Shims increasing portability of `Code` module
  """

  alias ElixirSense.Core.Behaviours
  alias ElixirSense.Core.ErlangHtml

  @type doc_t :: nil | false | String.t()
  @type fun_doc_entry_t ::
          {{atom, non_neg_integer}, pos_integer, :function | :macro, term, doc_t, map}
  @type doc_entry_t ::
          {{atom, non_neg_integer}, pos_integer, :callback | :macrocallback | :type, doc_t, map}
  @type moduledoc_entry_t :: {pos_integer, doc_t, map}

  @supported_mime_types ["text/markdown", "application/erlang+html"]

  @doc """
  Shim to replicate the behavior of deprecated `Code.get_docs/2`
  """
  @spec get_docs(module, :docs) :: nil | [fun_doc_entry_t]
  @spec get_docs(module, :callback_docs | :type_docs) :: nil | [:doc_entry_t]
  @spec get_docs(module, :moduledoc) :: nil | moduledoc_entry_t
  def get_docs(module, category) do
    case Code.fetch_docs(module) do
      {:docs_v1, moduledoc_anno, _language, mime_type, moduledoc, metadata, docs}
      when mime_type in @supported_mime_types ->
        case category do
          :moduledoc ->
            moduledoc_en = extract_docs(moduledoc, mime_type)

            {:erl_anno.line(moduledoc_anno), moduledoc_en, metadata}

          :docs ->
            get_fun_docs(module, docs, mime_type)

          :callback_docs ->
            for {{kind, _name, _arity}, _anno, _signatures, _docs, _metadata} = entry
                when kind in [:callback, :macrocallback] <- docs do
              map_doc_entry(entry, mime_type)
            end

          :type_docs ->
            for {{:type, _name, _arity}, _anno, _signatures, _docs, _metadata} = entry <- docs do
              map_doc_entry(entry, mime_type)
            end
        end

      _ ->
        nil
    end
  end

  defp map_doc_entry({{kind, name, arity}, anno, signatures, docs, metadata}, mime_type) do
    docs_en = extract_docs(docs, mime_type)
    line = :erl_anno.line(anno)

    case kind do
      kind when kind in [:function, :macro] ->
        args_quoted =
          signatures
          |> Enum.join(" ")
          |> Code.string_to_quoted()
          |> case do
            {:ok, {^name, _, args}} -> args
            _ -> []
          end

        {{name, arity}, line, kind, args_quoted, docs_en, metadata}

      _ ->
        {{name, arity}, line, kind, docs_en, metadata}
    end
  end

  @spec extract_docs(%{required(String.t()) => String.t()} | :hidden | :none, String.t()) ::
          String.t() | false | nil
  def extract_docs(%{"en" => docs_en}, "text/markdown"), do: docs_en

  def extract_docs(%{"en" => docs_en}, "application/erlang+html") do
    ErlangHtml.to_markdown(docs_en)
  end

  def extract_docs(:hidden, _), do: false
  def extract_docs(_, _), do: nil

  defp get_fun_docs(module, docs, mime_type) do
    docs_from_module =
      Enum.filter(
        docs,
        &match?(
          {{kind, _name, _arity}, _anno, _signatures, _docs, _metadata}
          when kind in [:function, :macro],
          &1
        )
      )

    non_documented =
      docs_from_module
      |> Stream.filter(fn {{_kind, _name, _arity}, _anno, _signatures, docs, _metadata} ->
        docs in [:hidden, :none] or not Map.has_key?(docs, "en")
      end)
      |> Enum.into(MapSet.new(), fn {{_kind, name, arity}, _anno, _signatures, _docs, _metadata} ->
        {name, arity}
      end)

    docs_from_behaviours = get_docs_from_behaviour(module, non_documented)

    Enum.map(
      docs_from_module,
      fn
        {{kind, name, arity}, anno, fun_signatures, docs, metadata} ->
          # IO.inspect signatures, label: "from mod"
          # as of elixir 1.14 behaviours do not store signature
          # prefer signature from function
          {_behaviour_signatures, docs, metadata, mime_type} =
            Map.get(
              docs_from_behaviours,
              {name, arity},
              {fun_signatures, docs, metadata, mime_type}
            )

          # IO.inspect signatures, label: "from beh"
          {{kind, name, arity}, anno, fun_signatures, docs, metadata}
          |> map_doc_entry(mime_type)
      end
    )
  end

  defp get_docs_from_behaviour(module, funs) do
    if Enum.empty?(funs) do
      # Small optimization to avoid needless analysis of behaviour modules if the collection of
      # required functions is empty.
      %{}
    else
      module
      |> Behaviours.get_module_behaviours()
      |> Stream.flat_map(&callback_documentation/1)
      |> Stream.filter(fn {name_arity, {_signatures, _docs, _metadata, _mime_type}} ->
        Enum.member?(funs, name_arity)
      end)
      |> Enum.into(%{})
    end
  end

  def callback_documentation(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _moduledoc_anno, _language, mime_type, _moduledoc, _metadata, docs}
      when mime_type in @supported_mime_types ->
        docs
        |> Stream.filter(
          &match?(
            {{kind, _name, _arity}, _anno, _signatures, _docs, _metadata}
            when kind in [:callback, :macrocallback],
            &1
          )
        )
        |> Stream.map(fn {{_kind, name, arity}, _anno, signatures, docs, metadata} ->
          {{name, arity},
           {signatures, docs, metadata |> Map.put(:implementing, module), mime_type}}
        end)

      _ ->
        []
    end
  end
end
