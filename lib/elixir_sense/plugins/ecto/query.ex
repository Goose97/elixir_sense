defmodule ElixirSense.Plugins.Ecto.Query do
  @moduledoc false

  alias ElixirSense.Core.Introspection
  alias ElixirSense.Core.Metadata
  alias ElixirSense.Core.Source
  alias ElixirSense.Core.State
  alias ElixirSense.Providers.Suggestion.Complete

  # We'll keep these values hard-coded until Ecto provides the same information
  # using docs' metadata.

  @joins [
    :join,
    :inner_join,
    :cross_join,
    :left_join,
    :right_join,
    :full_join,
    :inner_lateral_join,
    :left_lateral_join
  ]

  @from_join_opts [
    as: "A named binding for the from/join.",
    prefix: "The prefix to be used for the from/join when issuing a database query.",
    hints: "A string or a list of strings to be used as database hints."
  ]

  @join_opts [on: "A query expression or keyword list to filter the join."]

  @var_r "[a-z][a-zA-Z0-9_]*"
  @mod_r "[A-Z][a-zA-Z0-9_]*"
  @binding_r "(#{@var_r}) in (#{@mod_r}|assoc\\(\\s*#{@var_r},\\s*\\:#{@var_r}\\s*\\))"

  def find_assoc_suggestions(type, hint) do
    for assoc <- type.__schema__(:associations),
        assoc_str = inspect(assoc),
        String.starts_with?(assoc_str, hint) do
      assoc_mod = type.__schema__(:association, assoc).related
      {doc, _} = Introspection.get_module_docs_summary(assoc_mod)

      %{
        type: :generic,
        kind: :field,
        label: assoc_str,
        detail: "(Ecto association) #{inspect(assoc_mod)}",
        documentation: doc
      }
    end
  end

  def find_options(hint) do
    clauses_suggestions(hint) ++ joins_suggestions(hint) ++ join_opts_suggestions(hint)
  end

  defp clauses_suggestions(hint) do
    funs = Complete.get_module_funs(Ecto.Query, false)

    for {name, arity, arity, :macro, {doc, _}, _, "query," <> _} <- funs,
        clause = to_string(name),
        String.starts_with?(clause, hint) do
      clause_to_suggestion(clause, doc, "from clause")
    end
  end

  defp joins_suggestions(hint) do
    for name <- @joins -- [:join],
        clause = to_string(name),
        String.starts_with?(clause, hint) do
      join_kind = String.replace(clause, "_", " ")
      doc = "A #{join_kind} query expression."
      clause_to_suggestion(clause, doc, "from clause")
    end
  end

  defp join_opts_suggestions(hint) do
    for {name, doc} <- @join_opts ++ @from_join_opts,
        clause = to_string(name),
        String.starts_with?(clause, hint) do
      type = if Keyword.has_key?(@join_opts, name), do: "join", else: "from/join"
      clause_to_suggestion(clause, doc, "#{type} option")
    end
  end

  defp find_fields(type, hint) do
    with {:module, _} <- Code.ensure_compiled(type),
         true <- function_exported?(type, :__schema__, 1) do
      for field <- Enum.sort(type.__schema__(:fields)),
          name = to_string(field),
          String.starts_with?(name, hint) do
        %{name: field, type: type.__schema__(:type, field)}
      end
    else
      _ ->
        []
    end
  end

  defp find_field_relations(field, type) do
    associations = type.__schema__(:associations)

    for assoc_name <- associations,
        assoc = type.__schema__(:association, assoc_name),
        assoc.owner == type,
        assoc.owner_key == field.name do
      assoc
    end
  end

  def bindings_suggestions(hint, bindings) do
    case String.split(hint, ".") do
      [var, field_hint] ->
        type = bindings[var][:type]

        type
        |> find_fields(field_hint)
        |> Enum.map(fn f -> field_to_suggestion(f, type) end)

      _ ->
        for {name, %{type: type}} <- bindings,
            String.starts_with?(name, hint) do
          binding_to_suggestion(name, type)
        end
    end
  end

  defp clause_to_suggestion(option, doc, detail) do
    doc_str =
      doc
      |> doc_sections()
      |> Enum.filter(fn {k, _v} -> k in [:summary, "Keywords examples", "Keywords example"] end)
      |> Enum.map_join("\n\n", fn
        {:summary, text} ->
          text

        {_, text} ->
          [first | _] = String.split(text, "\n\n")
          if first == "", do: "", else: "### Example\n\n#{first}"
      end)

    %{
      type: :generic,
      kind: :property,
      label: option,
      insert_text: "#{option}: ",
      detail: "(#{detail}) Ecto.Query",
      documentation: doc_str
    }
  end

  defp binding_to_suggestion(binding, type) do
    {doc, _} = Introspection.get_module_docs_summary(type)

    %{
      type: :generic,
      kind: :variable,
      label: binding,
      detail: "(query binding) #{inspect(type)}",
      documentation: doc
    }
  end

  defp field_to_suggestion(field, origin) do
    type_str = inspect(field.type)
    associations = find_field_relations(field, origin)

    relations =
      Enum.map_join(associations, ", ", fn assoc ->
        "`#{inspect(assoc.related)} (#{inspect(assoc.related_key)})`"
      end)

    related_info = if relations == "", do: "", else: "* **Related:** #{relations}"

    doc = """
    The `#{inspect(field.name)}` field of `#{inspect(origin)}`.

    * **Type:** `#{type_str}`
    #{related_info}
    """

    %{
      type: :generic,
      kind: :field,
      label: to_string(field.name),
      detail: "Ecto field",
      documentation: doc
    }
  end

  defp infer_type({:__aliases__, _, _} = mod_ast, _vars, env, buffer_metadata) do
    mod = Macro.expand_once(mod_ast, %Macro.Env{})
    {actual_mod, _, _} = actual_mod_fun({mod, nil}, false, env, buffer_metadata)
    actual_mod
  end

  defp infer_type({:assoc, _, [{var, _, _}, assoc]}, vars, _env, _buffer_metadata) do
    var_type = vars[to_string(var)][:type]

    if var_type && function_exported?(var_type, :__schema__, 2) do
      var_type.__schema__(:association, assoc).related
    end
  end

  defp infer_type(_, _vars, _env, _buffer_metadata) do
    nil
  end

  def extract_bindings(prefix, %{pos: {{line, col}, _}} = func_info, env, buffer_metadata) do
    func_code = Source.text_after(prefix, line, col)

    from_matches = Regex.scan(~r/^.+\(?\s*(#{@binding_r})/, func_code)

    join_matches =
      for {join, {line, col, _}} when join in @joins <- func_info.options_so_far,
          code = Source.text_after(prefix, line, col),
          match <- Regex.scan(~r/^#{join}\:\s*(#{@binding_r})/, code) do
        match
      end

    matches = from_matches ++ join_matches

    Enum.reduce(matches, %{}, fn [_, _, var, expr], bindings ->
      case Code.string_to_quoted(expr) do
        {:ok, expr_ast} ->
          type = infer_type(expr_ast, bindings, env, buffer_metadata)
          Map.put(bindings, var, %{type: type})

        _ ->
          bindings
      end
    end)
  end

  def extract_bindings(_prefix, _func_info, _env, _buffer_metadata) do
    %{}
  end

  defp doc_sections(doc) do
    [summary_and_detail | rest] = String.split(doc, "##")
    summary_and_detail_parts = Source.split_lines(summary_and_detail, parts: 2)
    summary = summary_and_detail_parts |> Enum.at(0, "") |> String.trim()
    detail = summary_and_detail_parts |> Enum.at(1, "") |> String.trim()

    sections =
      Enum.map(rest, fn text ->
        [title, body] = Source.split_lines(text, parts: 2)
        {String.trim(title), String.trim(body, "\n")}
      end)

    [{:summary, summary}, {:detail, detail}] ++ sections
  end

  # TODO: Centralize
  defp actual_mod_fun({mod, fun}, elixir_prefix, env, buffer_metadata) do
    %State.Env{imports: imports, aliases: aliases, module: module} = env
    %Metadata{mods_funs_to_positions: mods_funs, types: metadata_types} = buffer_metadata

    Introspection.actual_mod_fun(
      {mod, fun},
      imports,
      if(elixir_prefix, do: [], else: aliases),
      module,
      mods_funs,
      metadata_types
    )
  end
end