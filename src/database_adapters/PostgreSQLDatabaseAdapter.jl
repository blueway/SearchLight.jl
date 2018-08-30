module PostgreSQLDatabaseAdapter

using LibPQ, DataFrames, DataStreams,  Nullables
using SearchLight, SearchLight.Database, SearchLight.Loggers

export DatabaseHandle, ResultHandle


#
# Setup
#


const DB_ADAPTER = LibPQ
const DEFAULT_PORT = 5432

const COLUMN_NAME_FIELD_NAME = :column_name

const DatabaseHandle = DB_ADAPTER.Connection
const ResultHandle   = DB_ADAPTER.Result

const TYPE_MAPPINGS = Dict{Symbol,Symbol}( # Julia / Postgres
  :char       => :CHARACTER,
  :string     => :VARCHAR,
  :text       => :TEXT,
  :integer    => :INTEGER,
  :int        => :INTEGER,
  :float      => :FLOAT,
  :decimal    => :DECIMAL,
  :datetime   => :DATETIME,
  :timestamp  => :INTEGER,
  :time       => :TIME,
  :date       => :DATE,
  :binary     => :BLOB,
  :boolean    => :BOOLEAN,
  :bool       => :BOOLEAN
)


"""
    db_adapter()::Symbol

The name of the underlying database adapter (driver).
"""
function db_adapter()::Symbol
  Symbol(DB_ADAPTER)
end


#
# Connection
#


"""
    connect(conn_data::Dict{String,Any})::DatabaseHandle

Connects to the database and returns a handle.
"""
function connect(conn_data::Dict{String,Any})::DatabaseHandle
  dns = String[]
  get!(conn_data, "host", nothing) != nothing      && push!(dns, "host=" * conn_data["host"])
  get!(conn_data, "hostaddr", nothing) != nothing  && push!(dns, "hostaddr=" * conn_data["hostaddr"])
  get!(conn_data, "port", nothing) != nothing      && push!(dns, "port=" * string(conn_data["port"]))
  get!(conn_data, "database", nothing) != nothing  && push!(dns, "dbname=" * conn_data["database"])
  get!(conn_data, "username", nothing) != nothing  && push!(dns, "user=" * conn_data["username"])
  get!(conn_data, "password", nothing) != nothing  && push!(dns, "password=" * conn_data["password"])
  get!(conn_data, "passfile", nothing) != nothing  && push!(dns, "passfile=" * conn_data["passfile"])
  get!(conn_data, "connecttimeout", nothing) != nothing  && push!(dns, "connect_timeout=" * conn_data["connecttimeout"])
  get!(conn_data, "clientencoding", nothing) != nothing  && push!(dns, "client_encoding=" * conn_data["clientencoding"])

  try
    DB_ADAPTER.Connection(join(dns, " "))
  catch ex
    log("Invalid DB connection settings", :err)
    log(string(ex), :err)
    log("$(@__FILE__):$(@__LINE__)", :err)

    rethrow(ex)
  end
end


"""
    disconnect(conn::DatabaseHandle)::Nothing

Disconnects from database.
"""
function disconnect(conn::DatabaseHandle)::Nothing
  DB_ADAPTER.close(conn)
end


#
# Utility
#


"""
    table_columns_sql(table_name::String)::String

Returns the adapter specific query for SELECTing table columns information corresponding to `table_name`.
"""
function table_columns_sql(table_name::String)::String
  # "SELECT
  #   column_name, ordinal_position, column_default, is_nullable, data_type, character_maximum_length,
  #   udt_name, is_identity, is_updatable
  # FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = '$table_name'"
  "SELECT column_name FROM INFORMATION_SCHEMA.COLUMNS WHERE table_name = '$table_name'"
end


"""
    create_migrations_table(table_name::String)::Bool

Runs a SQL DB query that creates the table `table_name` with the structure needed to be used as the DB migrations table.
The table should contain one column, `version`, unique, as a string of maximum 30 chars long.
Returns `true` on success.
"""
function create_migrations_table(table_name::String)::Bool
  "CREATE TABLE $table_name (version varchar(30))" |> Database.query

  log("Created table $table_name")

  true
end


#
# Data sanitization
#


"""
    escape_column_name(c::String, conn::DatabaseHandle)::String

Escapes the column name.

# Examples
```julia
julia>
```
"""
function escape_column_name(c::String, conn::DatabaseHandle)::String
  """\"$(replace(c, "\""=>"'"))\""""
end


"""
    escape_value{T}(v::T, conn::DatabaseHandle)::T

Escapes the value `v` using native features provided by the database backend if available.

# Examples
```julia
julia>
```
"""
function escape_value(v::T, conn::DatabaseHandle)::T where {T}
  isa(v, Number) ? v : "E'$(replace(string(v), "'"=>"\\'"))'"
end


#
# Query execution
#


"""
    query_df(sql::String, suppress_output::Bool, conn::DatabaseHandle)::DataFrames.DataFrame

Executes the `sql` query against the database backend and returns a DataFrame result.

# Examples:
```julia
julia> PostgreSQLDatabaseAdapter.query_df(SearchLight.to_fetch_sql(Article, SQLQuery(limit = 5)), false, Database.connection())

2017-01-16T21:36:21.566 - info: SQL QUERY: SELECT \"articles\".\"id\" AS \"articles_id\", \"articles\".\"title\" AS \"articles_title\", \"articles\".\"summary\" AS \"articles_summary\", \"articles\".\"content\" AS \"articles_content\", \"articles\".\"updated_at\" AS \"articles_updated_at\", \"articles\".\"published_at\" AS \"articles_published_at\", \"articles\".\"slug\" AS \"articles_slug\" FROM \"articles\" LIMIT 5

  0.000985 seconds (16 allocations: 576 bytes)

5×7 DataFrames.DataFrame
...
```
"""
function query_df(sql::String, suppress_output::Bool, conn::DatabaseHandle)::DataFrames.DataFrame
  DB_ADAPTER.fetch!(DataFrames.DataFrame, query(sql, suppress_output, conn))
end


"""

"""
function query(sql::String, suppress_output::Bool, conn::DatabaseHandle)::ResultHandle
  # stmt = DB_ADAPTER.prepare(conn, sql)

  result = if suppress_output || ( ! SearchLight.config.log_db && ! SearchLight.config.log_queries )
    DB_ADAPTER.execute(conn, sql)
  else
    log("SQL QUERY: $sql")
    @time DB_ADAPTER.execute(conn, sql)
  end
  # DB_ADAPTER.close(conn)

  if ( DB_ADAPTER.error_message(result) != "" )
    error("$(string(DB_ADAPTER)) error: $(DB_ADAPTER.errstring(result)) [$(DB_ADAPTER.errcode(result))]")
  end

  result
end


"""

"""
function relation_to_sql(m::T, rel::Tuple{SQLRelation,Symbol})::String where {T<:AbstractModel}
  rel, rel_type = rel
  j = disposable_instance(rel.model_name)
  join_table_name = table_name(j)

  if rel_type == RELATION_BELONGS_TO
    j, m = m, j
  end

  (join_table_name |> Database.escape_column_name) * " ON " *
    (table_name(j) |> Database.escape_column_name) * "." *
    ( (lowercase(string(typeof(m))) |> SearchLight.strip_module_name) * "_" * primary_key_name(m) |> Database.escape_column_name) *
    " = " *
    (table_name(m) |> Database.escape_column_name) * "." *
    (primary_key_name(m) |> Database.escape_column_name)
end


"""

"""
function to_find_sql(m::Type{T}, q::SQLQuery, joins::Vector{SQLJoin{N}})::String where {T<:AbstractModel, N<:AbstractModel}
  sql::String = ( "$(to_select_part(m, q.columns, joins)) $(to_from_part(m)) $(to_join_part(m, joins)) $(to_where_part(m, q.where, q.scopes)) " *
                      "$(to_group_part(q.group)) $(to_having_part(q.having)) $(to_order_part(m, q.order)) " *
                      "$(to_limit_part(q.limit)) $(to_offset_part(q.offset))") |> strip
  replace(sql, r"\s+"=>" ")
end
function to_find_sql(m::Type{T}, q::SQLQuery)::String where {T<:AbstractModel}
  sql::String = ( "$(to_select_part(m, q.columns)) $(to_from_part(m)) $(to_join_part(m)) $(to_where_part(m, q.where, q.scopes)) " *
                      "$(to_group_part(q.group)) $(to_having_part(q.having)) $(to_order_part(m, q.order)) " *
                      "$(to_limit_part(q.limit)) $(to_offset_part(q.offset))") |> strip
  replace(sql, r"\s+"=>" ")
end
const to_fetch_sql = to_find_sql


"""

"""
function to_store_sql(m::T; conflict_strategy = :error)::String where {T<:AbstractModel} # upsert strateygy = :none | :error | :ignore | :update
  uf = persistable_fields(m)

  sql = if ! is_persisted(m) || (is_persisted(m) && conflict_strategy == :update)
    pos = findfirst(uf, primary_key_name(m))
    pos > 0 && splice!(uf, pos)

    fields = SQLColumn(uf)
    vals = join( map(x -> string(to_sqlinput(m, Symbol(x), getfield(m, Symbol(x)))), uf), ", ")

    "INSERT INTO $(table_name(m)) ( $fields ) VALUES ( $vals )" *
        if ( conflict_strategy == :error ) ""
        elseif ( conflict_strategy == :ignore ) " ON CONFLICT DO NOTHING"
        elseif ( conflict_strategy == :update && ! isnull( getfield(m, Symbol(primary_key_name(m))) ) )
           " ON CONFLICT ($(primary_key_name(m))) DO UPDATE SET $(update_query_part(m))"
        else ""
        end
  else
    "UPDATE $(table_name(m)) SET $(update_query_part(m))"
  end

  return sql * " RETURNING $(primary_key_name(m))"
end


"""

"""
function delete_all(m::Type{T}; truncate::Bool = true, reset_sequence::Bool = true, cascade::Bool = false)::Nothing where {T<:AbstractModel}
  _m::T = m()
  if truncate
    sql = "TRUNCATE $(table_name(_m))"
    reset_sequence ? sql * " RESTART IDENTITY" : ""
    cascade ? sql * " CASCADE" : ""
  else
    sql = "DELETE FROM $(table_name(_m))"
  end

  SearchLight.query(sql)

  nothing
end


"""

"""
function delete(m::T)::T where {T<:AbstractModel}
  sql = "DELETE FROM $(table_name(m)) WHERE $(primary_key_name(m)) = '$(m.id |> Base.get)'"
  SearchLight.query(sql)

  tmp::T = T()
  m.id = tmp.id

  m
end


"""

"""
function count(m::Type{T}, q::SQLQuery = SQLQuery())::Int where {T<:AbstractModel}
  count_column = SQLColumn("COUNT(*) AS __cid", raw = true)
  q = SearchLight.clone(q, :columns, push!(q.columns, count_column))

  find_df(m, q)[1, Symbol("__cid")]
end


"""

"""
function update_query_part(m::T)::String where {T<:AbstractModel}
  update_values = join(map(x -> "$(string(SQLColumn(x))) = $( string(to_sqlinput(m, Symbol(x), getfield(m, Symbol(x)))) )", persistable_fields(m)), ", ")

  " $update_values WHERE $(table_name(m)).$(primary_key_name(m)) = '$(Base.get(m.id))'"
end


"""

"""
function column_data_to_column_name(column::SQLColumn, column_data::Dict{Symbol,Any})::String
  "$(to_fully_qualified(column_data[:column_name], column_data[:table_name])) AS $( isempty(column_data[:alias]) ? SearchLight.to_sql_column_name(column_data[:column_name], column_data[:table_name]) : column_data[:alias] )"
end


"""

"""
function to_select_part(m::Type{T}, cols::Vector{SQLColumn}, joins = SQLJoin[])::String where {T<:AbstractModel}
  "SELECT " * Database._to_select_part(m, cols, joins)
end


"""

"""
function to_from_part(m::Type{T})::String where {T<:AbstractModel}
  "FROM " * Database.escape_column_name(table_name(disposable_instance(m)))
end


"""

"""
function to_where_part(m::Type{T}, w::Vector{SQLWhereEntity}, scopes::Vector{Symbol})::String where {T<:AbstractModel}
  w = vcat(w, required_scopes(m)) # automatically include required scopes

  _m::T = m()
  for scope in scopes
    w = vcat(w, _m.scopes[scope])
  end

  to_where_part(w)
end
function to_where_part(w::Vector{SQLWhereEntity})::String
  where = isempty(w) ?
          "" :
          "WHERE " * (string(first(w).condition) == "AND" ? "TRUE " : "FALSE ") * join(map(wx -> string(wx), w), " ")

  replace(where, r"WHERE TRUE AND "i => "WHERE ")
end


"""

"""
function required_scopes(m::Type{T})::Vector{SQLWhereEntity} where {T<:AbstractModel}
  s = scopes(m)
  haskey(s, :required) ? s[:required] : SQLWhereEntity[]
end


"""

"""
function scopes(m::Type{T})::Dict{Symbol,Vector{SQLWhereEntity}} where {T<:AbstractModel}
  in(:scopes, fieldnames(m)) ? getfield(m()::T, :scopes) :  Dict{Symbol,Vector{SQLWhereEntity}}()
end


"""

"""
function to_order_part(m::Type{T}, o::Vector{SQLOrder})::String where {T<:AbstractModel}
  isempty(o) ?
    "" :
    "ORDER BY " * join(map(x -> (! is_fully_qualified(x.column.value) ? to_fully_qualified(m, x.column) : x.column.value) * " " * x.direction, o), ", ")
end


"""

"""
function to_group_part(g::Vector{SQLColumn})::String
  isempty(g) ?
    "" :
    " GROUP BY " * join(map(x -> string(x), g), ", ")
end


"""

"""
function to_limit_part(l::SQLLimit)::String
  l.value != "ALL" ? "LIMIT " * (l |> string) : ""
end


"""

"""
function to_offset_part(o::Int)::String
  o != 0 ? "OFFSET " * (o |> string) : ""
end


"""

"""
function to_having_part(h::Vector{SQLWhereEntity})::String
  having =  isempty(h) ?
            "" :
            "HAVING " * (string(first(h).condition) == "AND" ? "TRUE " : "FALSE ") * join(map(w -> string(w), h), " ")

  replace(having, r"HAVING TRUE AND "i => "HAVING ")
end


"""

"""
function to_join_part(m::Type{T}, joins = SQLJoin[])::String where {T<:AbstractModel}
  _m::T = m()
  join_part = ""

  for rel in relations(m)
    mr = first(rel)
    ( mr |> is_lazy ) && continue
    if ! isnull(mr.join)
      join_part *= mr.join |> Base.get |> string
    else # default
      join_part *= (mr.required ? "INNER " : "LEFT ") * "JOIN " * relation_to_sql(_m, rel)
    end
  end

  join_part * join( map(x -> string(x), joins), " " )
end


"""
    cast_type(v::Bool)::Union{Bool,Int,Char,String}

Converts the Julia type to the corresponding type in the database.
"""
function cast_type(v::Bool)::Union{Bool,Int,Char,String}
  v ? "true" : "false"
end

"""

"""
function create_table_sql(f::Function, name::String, options::String = "")::String
  "CREATE TABLE $name (" * join(f()::Vector{String}, ", ") * ") $options" |> strip
end


"""

"""
function column_sql(name::String, column_type::Symbol, options::String = ""; default::Any = nothing, limit::Union{Int,Nothing} = nothing, not_null::Bool = false)::String
  "$name $(TYPE_MAPPINGS[column_type] |> string) " *
    (isa(limit, Int) ? "($limit)" : "") *
    (default == nothing ? "" : " DEFAULT $default ") *
    (not_null ? " NOT NULL " : "") *
    options
end


"""

"""
function column_id_sql(name::String = "id", options::String = ""; constraint::String = "", nextval::String = "")::String
  "$name SERIAL $constraint PRIMARY KEY $nextval $options"
end


"""

"""
function add_index_sql(table_name::String, column_name::String; name::String = "", unique::Bool = false, order::Symbol = :none)::String
  name = isempty(name) ? Database.index_name(table_name, column_name) : name
  "CREATE $(unique ? "UNIQUE" : "") INDEX $(name) ON $table_name ($column_name)"
end


"""

"""
function add_column_sql(table_name::String, name::String, column_type::Symbol; default::Any = nothing, limit::Union{Int,Nothing} = nothing, not_null::Bool = false)::String
  "ALTER TABLE $table_name ADD $(column_sql(name, column_type, default = default, limit = limit, not_null = not_null))"
end


"""

"""
function drop_table_sql(name::String)::String
  "DROP TABLE $name"
end


"""

"""
function remove_column_sql(table_name::String, name::String, options::String = "")::Nothing
  "ALTER TABLE $table_name DROP COLUMN $name $options"
end


"""

"""
function remove_index_sql(table_name::String, name::String, options::String = "")::String
  "DROP INDEX $name $options"
end


"""

"""
function create_sequence_sql(name::String)::String
  "CREATE SEQUENCE $name"
end


"""

"""
function remove_sequence_sql(name::String, options::String = "")::String
  "DROP SEQUENCE $name $options"
end


"""

"""
function rand(m::Type{T}; limit = 1)::Vector{T} where {T<:AbstractModel}
  SearchLight.find(m, SQLQuery(limit = SQLLimit(limit), order = [SQLOrder("random()", raw = true)]))
end
function rand(m::Type{T}, scopes::Vector{Symbol}; limit = 1)::Vector{T} where {T<:AbstractModel}
  SearchLight.find(m, SQLQuery(limit = SQLLimit(limit), order = [SQLOrder("random()", raw = true)], scopes = scopes))
end

end
