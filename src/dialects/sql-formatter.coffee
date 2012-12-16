_ = require('more-underscore/src')
sql = require('../sql')
{ SqlJoin, SqlFrom, SqlToken, SqlRawName, SqlFullName } = sql

rgxParseName = ///
    ( [^.]+ )   # anything that's not a .
    \.?         # optional . at the end
///g

rgxExpression = /[()\+\*\-/]/
rgxPatternMetaChars = /[%_[]/g

operatorAliases = {
    contains: 'LIKE'
    startsWith: 'LIKE'
    endsWith: 'LIKE'
    equals: '='
    '!=': '<>'
}

class SqlFormatter
    constructor: (@db) ->
        @sources = []

    f: (v) ->
        return v.toSql(@) if v instanceof SqlToken
        return @literal(v)

    literal: (l) ->
        unless l?
            return 'NULL'

        if (_.isString(l))
            return "'" + l.replace("'","''") + "'"

        if (_.isArray(l))
            return _.map(l, (i) => @literal(i)).join(', ')

        return l.toString()

    parens: (contents) -> "(#{contents.toSql(@)})"

    isExpression: (e) -> _.isString(e) && rgxExpression.test(e)

    and: (terms) ->
        t = _.map(terms, @f, @)
        return "(#{t.join(" AND " )})"

    or: (terms) ->
        t = _.map(terms, @f, @)
        return "(#{t.join(" OR " )})"

    rawName: (n) -> @parseWhenRawName(n).toSql(@)

    fullName: (m) -> @joinNameParts(m.parts)

    joinNameParts: (names) -> _.map(names, (p) -> "[#{p}]").join(".")

    parseWhenRawName: (t) ->
        if t instanceof SqlFullName
            return t

        if t instanceof SqlRawName
            return @fullNameFromString(t.name)

        return t

    fullNameFromString: (s) ->
        parts = []
        while (match = rgxParseName.exec(s))
            parts.push(match[1])

        return new SqlFullName(parts)

    delimit: (s) -> "[#{s}]"

    column: (c) ->
        atom = _.firstOrSelf(c)
        alias = _.secondOrNull(c)
        return @_doColumnAtom(atom, @_doAliasedColumn, alias)

    _doAliasedColumn: (token, schema, alias) ->
        s = @_doToken(token, schema)
        alias = @_doAlias(token, schema, alias)
        if (alias? && alias != schema?.name)
            s += " as #{@delimit(alias)}"

        return s

    # A column might be an actual table column, but it could also be an expression,
    # SQL literal, subquery, etc.
    _doColumnAtom: (atom, fn = @_doToken, p = null) ->
        token = @tokenizeAtom(atom)
        columnSchema = @_findColumnSchema(token)
        return fn.call(@, token, columnSchema, p)

    _doToken: (token, schema) ->
        if (schema?)
            # MUST: we assume the column is a DB object at this point. We'll need to handle
            # virtual tables, columns, etc. one day
            if (p = token.prefix())
                return @joinNameParts([p, schema.name])
            else
                return @delimit(schema.name)
        else
            return @f(token)

    _doAlias: (token, schema, alias) ->
        if alias?
            return alias

        if schema?
            return schema.alias

        return null

    _doAliasedExpression: (token, schema, alias) ->
        e = @_doToken(token, schema)
        a = @_doAlias(token, schema, alias)

        return e unless a?

        a = @delimit(a)
        return if e != a then "#{e} as #{a}" else e

    naryOp: (op, atoms) ->
        switch op
            when 'isNull'
                pieces = ("#{@_doColumnAtom(a)} IS NULL" for a in atoms)
            when 'isntNull', 'isNotNull'
                pieces = ("#{@_doColumnAtom(a)} IS NOT NULL" for a in atoms)
            when 'isGood'
                pieces = []
                for a in atoms
                    s = @_doColumnAtom(a)
                    pieces.push("#{s} IS NOT NULL AND LEN(RTRIM(LTRIM(#{s}))) > 0")

        return pieces.join(' AND ')

    binaryOp: (left, op, right) ->
        l = @_doColumnAtom(left)
        
        sqlOp = operatorAliases[op] ? op.toUpperCase()
        
        switch op
            when 'in' then r = "(#{@f(right)})"
            when 'between' then r = "#{@f(right[0])} AND #{@f(right[1])}"
            when 'contains'
                r = @_doPatternMatch(right, '%', '%')
            when 'startsWith'
                r = @_doPatternMatch(right, '', '%')
            when 'endsWith'
                r = @_doPatternMatch(right, '%')
            else
                rightToken = @parseWhenRawName(right)
                schema = @_findColumnSchema(rightToken)
                r = @_doToken(rightToken, schema)

        return "#{l} #{sqlOp} #{r}"

    _doPatternMatch: (rhs, prologue = '', epilogue = '') ->
        t = @parseWhenRawName(rhs)
        schema = @_findColumnSchema(t)

        if sql.isLiteral(t)
            p = _.undelimit(@f(rhs), "''")
            p = @_escapePatternMetaChars(p)
            return "'#{prologue}#{p}#{epilogue}'"
        else
            p = @_doToken(t)
            if prologue
                p = "'#{prologue}' + #{p}"
            if epilogue
                p = "#{p} + '#{epilogue}'"
            return p

    _escapePatternMetaChars: (s) -> s.replace(rgxPatternMetaChars, '[$&]')

    functionCall: (call) ->
        switch call.name
            when 'now' then return 'GETDATE()'
            when 'utcNow' then return 'GETUTCDATE()'
            when 'trim'
                prologue = "RTRIM(LTRIM("
                epilogue = "))"
            else
                prologue = "#{call.name.toUpperCase()}("
                epilogue = ")"

        if call.args.length == 0
            return prologue + epilogue

        @doList(call.args, @_doColumnAtom, ', ', prologue, epilogue)


    doList: (collection, fn = @f, separator = ', ', prologue = '', epilogue = '') ->
        return '' unless collection?.length > 0
        results = (fn.call(@, i) for i in collection)
        return prologue + results.join(separator) + epilogue

    columns: (columnList) ->
        return "*" if (columnList.length == 0)
        return @doList(columnList, @column)

    _doTables: -> @doList((s for s in @sources when s instanceof SqlFrom))

    _doJoins: -> @doList((s for s in @sources when s instanceof SqlJoin), @f, ' ')

    from: (f) ->
        token = f._token
        schema = f._schema
        return @_doAliasedExpression(f._token, f._schema, f.alias)

    join: (j) ->
        str = " INNER JOIN " + @from(j) + " ON " + @f(j.predicate)

    tokenizeAtom: (atom) ->
        n = @parseWhenRawName(atom)
        if n instanceof SqlFullName
            return n

        if @isExpression(atom)
            return sql.expr(atom)

        if _.isString(atom)
            return @fullNameFromString(atom)

        return atom

    cacheTokenFor: (e) -> e._token = @tokenizeAtom(e.atom)

    _findTableSchema: (token) ->
        unless token instanceof SqlFullName
            return null

        return @db.tablesByAlias[token.tip()] ? null

    _findColumnSchema: (token) ->
        unless token instanceof SqlFullName
            return

        table = token.prefix()
        if table?
            return @db.tablesByAlias[table]?.columnsByAlias[token.tip()]

        for t in @sources when t._schema?
            column = t._schema.columnsByAlias[token.tip()]
            if column?
                return column

    _addSources: (a, type) ->
        for o in a
            s = if o instanceof type then o else new type(o)
            @sources.push(s)
            token = @cacheTokenFor(s)
            s._schema = @_findTableSchema(token)

    _deductJoinPredicates: ->
        cnt = 1
        while cnt > 0
            cnt = 0
            for j in @sources when j instanceof SqlJoin && j.predicate == null
                cnt++ if @_findFkForJoin(j)

        # SHOULD: throw if there are still unresolved JOINS
        return

    _findFkForJoin: (j) ->
        unless j._schema?
            msg = "Unable to build predicate for #{j} because it is not backed " +
                "by a schema table"
            throw new Error(msg)

        t = j._schema

        viableSources =
            (s for s in @sources when s._schema? && (s instanceof SqlFrom || s.predicate?))

        parents =
            _.filter t.foreignKeys, (fk) =>
                _.some viableSources, (s) =>
                    s._schema == fk.parentTable

        if (parents.length > 0)
            # MAY: get smarter about picking which PK to use
            return @_joinByFk(j, parents[0])

        children =
            _.filter t.incomingFKs, (fk) =>
                _.some viableSources, (s) =>
                    s._schema == fk.table

        if (children.length > 0)
            return @_joinByFk(j, children[0])

        return false

    _joinByFk: (j, fk) ->
        childAlias = fk.table.alias
        parentAlias = fk.parentTable.alias
        parentKey = fk.parentKey

        terms = (for c, i in fk.columns
            [sql.name(childAlias, c.alias), sql.name(parentAlias, parentKey.columns[i].alias)]
        )
        j.predicate = sql.and(terms...)

        return true

    select: (sql) ->
        @_addSources(sql.tables, SqlFrom)
        @_addSources(sql.joins, SqlJoin)
        @_deductJoinPredicates()

        ret = "SELECT "
        if (sql.cntTake)
            ret += "TOP #{sql.cntTake} "

        ret += "#{@columns(sql.columns)}"
        ret += " FROM #{@_doTables()}" if sql.tables.length > 0

        ret += @_doJoins()
        ret += @where(sql)
        ret += @groupBy(sql)
        ret += @orderBy(sql)
        return ret

    where: (c) -> if c.whereClause? then " WHERE #{(c.whereClause.toSql(@))}"  else ''

    groupBy: (c) -> @doList(c.groupings, @_doColumnAtom, ', ', ' GROUP BY ')

    orderBy: (c) -> @doList(c.orderings, @ordering, ', ', ' ORDER BY ')

    ordering: (o) ->
        s = @_doColumnAtom(_.firstOrSelf(o))
        dir = if _.secondOrNull(o) == 'DESC' then 'DESC' else 'ASC'

        "#{s} #{dir}"

    _doTargetTable: (name) ->
        fullName = @parseWhenRawName(name)
        schema = @_findTableSchema(fullName)
        if schema?
            @sources.push(_schema: schema)
            @targetTableSchema = schema

        return @_doToken(fullName, schema)

    insert: (i) ->
        ret = "INSERT #{@_doTargetTable(i.targetTable)}"
        names = []
        values = []
        for k, v of i.values
            c = @_doColumnAtom(k, @_doInsertUpdateColumn)
            continue unless c
            names.push(c)
            values.push(@f(v))

        ret += " (#{names.join(', ')}) VALUES (#{values.join(', ')})"

    update: (u) ->
        ret = "UPDATE #{@_doTargetTable(u.targetTable)} SET "

        values = []
        for k, v of u.values
            c = @_doColumnAtom(k, @_doInsertUpdateColumn)
            continue unless c
            values.push("#{c} = #{@f(v)}")

        ret += values.join(', ')

        ret += @where(u)
        return ret

    _doInsertUpdateColumn: (token, columnSchema, s) ->
        if @targetTableSchema? && (not columnSchema? || columnSchema.isReadOnly)
            return false

        return @_doToken(token, columnSchema)

    delete: (d) ->
        ret = "DELETE FROM #{@_doTargetTable(d.targetTable)}"
        ret += @where(d)
        return ret

p = SqlFormatter.prototype
p.format = p.f

module.exports = SqlFormatter
