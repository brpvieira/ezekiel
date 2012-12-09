_ = require('more-underscore/src')
sql = require('../sql')
{ SqlLiteral, SqlPredicate, SqlToken, SqlSelect, SqlExpression, SqlRawName, SqlFullName } = sql

SqlIdentifier = SqlToken.SqlIdentifier

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
        @modelTables = []

    f: (v) ->
        return v.toSql(@) if v instanceof SqlToken
        return @literal(v)

    literal: (l) ->
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
        return @_doAtom(atom, alias, true)

    _doAtom: (atom, alias, addAlias = false) ->
        token = @tokenizeAtom(atom)
        model = @findColumnModel(token)
        s = @_doToken(token, model)

        if addAlias
            alias = @_doAlias(token, model, alias)
            if (alias?)
                s += " as #{@delimit(alias)}"

        return s

    _doToken: (token, model) ->
        if (model?)
            # MUST: we assume the column is a DB object at this point. We'll need to handle
            # virtual tables, columns, etc. one day
            if (p = token.prefix())
                return @joinNameParts([p, model.name])
            else
                return @delimit(model.name)
        else
            return @f(token)

    _doAlias: (token, model, alias) ->
        if alias?
            return alias

        if model?
            return model.alias

        return null

    _doAliasedExpression: (token, model, alias) ->
        e = @_doToken(token, model)
        a = @_doAlias(token, model, alias)

        return if a? then "#{e} as #{@delimit(a)}" else e

    naryOp: (op, atoms) ->
        switch op
            when 'isNull'
                pieces = ("#{@_doAtom(a)} IS NULL" for a in atoms)
            when 'isntNull', 'isNotNull'
                pieces = ("#{@_doAtom(a)} IS NOT NULL" for a in atoms)
            when 'isGood'
                pieces = []
                for a in atoms
                    s = @_doAtom(a)
                    pieces.push("#{s} IS NOT NULL AND LEN(RTRIM(LTRIM(#{s}))) > 0")

        return pieces.join(' AND ')

    binaryOp: (left, op, right) ->
        l = @_doAtom(left)
        
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
                model = @findColumnModel(rightToken)
                r = @_doToken(rightToken, model)

        return "#{l} #{sqlOp} #{r}"

    _doPatternMatch: (rhs, prologue = '', epilogue = '') ->
        t = @parseWhenRawName(rhs)
        model = @findColumnModel(t)

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

        @doList(call.args, @_doAtom, ', ', prologue, epilogue)


    doList: (collection, fn = @f, separator = ', ', prologue = '', epilogue = '') ->
        return '' unless collection?.length > 0
        results = (fn.call(@, i) for i in collection)
        return prologue + results.join(separator) + epilogue

    columns: (columnList) ->
        return "*" if (columnList.length == 0)
        return @doList(columnList, @column)

    tables: (tableList) -> @doList(tableList)

    joins: (joinList) -> @doList(joinList, @f, ' ')

    from: (f) ->
        token = f._token
        model = f._model
        return @_doAliasedExpression(f._token, f._model, f.alias)

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

    cacheExpressionToken: (e) -> e._token = @tokenizeAtom(e.atom)

    findColumnModel: (name) ->
        unless name instanceof SqlFullName
            return

        table = name.prefix()
        if table?
            return @db.tablesByAlias[table]?.columnsByAlias[name.tip()]

        for t in @modelTables
            column = t.columnsByAlias[name.tip()]
            if column?
                return column

    addTables: (a) ->
        for t in a
            token = @cacheExpressionToken(t)
            if (token instanceof SqlFullName)
                t._model = @db.tablesByAlias[token.tip()]
                @modelTables.push(t._model) if t._model?

    select: (sql) ->
        @addTables(sql.tables)
        @addTables(sql.joins)

        ret = "SELECT "
        if (sql.cntTake)
            ret += "TOP #{sql.cntTake} "

        ret += "#{@columns(sql.columns)} FROM #{@tables(sql.tables)}"

        ret += @joins(sql.joins)
        ret += @where(sql)
        ret += @groupBy(sql)
        ret += @orderBy(sql)
        return ret

    where: (c) -> if c.whereClause? then " WHERE #{(c.whereClause.toSql(@))}"  else ''

    groupBy: (c) -> @doList(c.groupings, @_doAtom, ', ', ' GROUP BY ')

    orderBy: (c) -> @doList(c.orderings, @ordering, ', ', ' ORDER BY ')

    ordering: (o) ->
        s = @_doAtom(_.firstOrSelf(o))
        dir = if _.secondOrNull(o) == 'DESC' then 'DESC' else 'ASC'

        "#{s} #{dir}"

    insert: (i) ->
        return "INSERT #{@f(i.targetTable)}"

    update: (u) ->
        ret = "UPDATE #{@f(u.targetTable)} SET "
        ret += @doList(u.exprs)
        ret += @where(u)
        return ret

    updateExpr: (e) -> "#{@f(e.column)} = #{@f(e.value)}"

    delete: (d) ->
        ret = "DELETE FROM #{@f(d.targetTable)}"
        ret += @where(d)
        return ret

p = SqlFormatter.prototype
p.format = p.f

module.exports = SqlFormatter
