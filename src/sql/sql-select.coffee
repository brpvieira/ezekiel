_ = require("underscore")
F = require('functoids/src')
{ SqlPredicate, SqlRawName, SqlStatement, SqlToken } = sql = require('./index')

class SqlAliasedExpression extends SqlToken
    constructor: (a) ->
        @atom = F.firstOrSelf(a)
        @alias = F.secondOrNull(a)

        # This is only used by formatters, users don't have to worry about it
        @_schema = null
        @_token = null

class SqlFrom extends SqlAliasedExpression
    toSql: (f) -> f.from(@)

class SqlJoin extends SqlAliasedExpression
    constructor: (a, predicate, type) ->
        super(a)
        @predicate = if predicate? then new SqlPredicate(predicate) else null
        @type = if type? then type else "INNER"

    toSql: (f) -> f.join(@)

class SqlSelect extends SqlStatement
    constructor: (tableList...) ->
        @columns = []
        @tables = []
        @joins = []
        @orderings = []
        @groupings = []

        (@from(t) for t in tableList)

    addFrom: (table, a) -> a.push(table)

    addColumns: (columns...) ->
        for col in columns
            if (_.isArray(col))
                @addColumn.apply(@, col)
                continue

            @addColumn(col)

        return @

    addColumn: (columns...) ->
        @columns.push(columns)
        return @

    select: (columns...) ->
        @columns = columns
        return @

    distinct: () ->
        @quantifier = "DISTINCT"
        return @

    all: () ->
        @quantifier = "ALL"
        return @

    skip: (n) ->
        @cntSkip = n
        return @

    take: (n) ->
        @cntTake = n
        return @

    from: (table) ->
        @tables.push(table)
        return @

    join: (j, clause, type) ->
        join = if clause? then sql.join(j, clause, type) else j
        @joins.push(join)
        return @

    leftJoin: (j, clause) ->
        return @join(j, clause, "LEFT")

    fullJoin: (j, clause) ->
        return @join(j, clause, "FULL OUTER")

    rightJoin: (j, clause) ->
        return @join(j, clause, "RIGHT")

    where: (terms...) ->
        @whereClause = @addTerms(@whereClause, terms)
        return @

    groupBy: (atoms...) ->
        @groupings.push(atoms...)
        return @

    having: (terms...) ->
        @havingClause = @addTerms(@havingClause, terms)
        return @

    addTerms: (predicate, terms) ->
        @lastPredicate = SqlPredicate.addOrCreate(predicate, terms)
        return @lastPredicate

    orderBy: (orderings...) ->
        @orderings.push(orderings...)
        return @

    and: (terms...) ->
        return @where(terms...) unless @lastPredicate

        @lastPredicate.and(terms...)
        return @

    or: (terms...) ->
        return @where(sql.or(terms...)) unless @lastPredicate
        @lastPredicate.or(terms...)
        return @

    toSql: (f) ->
        return f.select(@)

p = SqlSelect.prototype
p.limit = p.top = p.take

_.extend(sql, {
    select: (t...) ->
        s = new SqlSelect()
        s.select(t...)

    from: (t) -> new SqlSelect(t)
    join: (table, clause, type) -> new SqlJoin(table, clause, type)

    SqlSelect
    SqlJoin
    SqlFrom
})

module.exports = SqlSelect
