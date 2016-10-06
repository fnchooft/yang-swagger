# OPENAPI (swagger) specification feature

debug = require('debug')('yang:openapi') if process.env.DEBUG?
clone = require 'clone'
traverse = require 'traverse'
Yang = require 'yang-js'
yaml = require 'js-yaml'

# TODO: this should be handled via separate yang-json-schema module
definitions = {}
yang2jstype = (schema) ->
  js =
    description: schema.description?.tag
    default: schema.default?.tag
  return js unless schema.type?
  datatype = switch schema.type.primitive
    when 'uint8','int8'
      type: 'integer'
      format: 'byte'
    when 'uint16','uint32','uint64','int16','int32','int64'
      type: 'integer'
      format: schema.type.primitive
    when 'binary'
      type: 'string'
      format: 'binary'
    when 'decimal64'
      type: 'number'
      format: 'double'
    when 'union' # TODO
      type: 'string'
      format: schema.type.tag
      #anyOf: []
    when 'boolean'
      type: 'boolean'
      format: schema.type.tag
    when 'enumeration'
      type: 'string'
      format: schema.type.tag
      enum: schema.type.enum.map (e) -> e.tag
    else
      # TODO: handle pattern?
      type: 'string'
      format: schema.type.tag
  js[k] = v for k, v of datatype
  return js

yang2jsobj = (schema) ->
  return {} unless schema?
  debug? "[#{schema.trail}] converting schema to JSON-schema"
  js =
   description: schema.description?.tag
  required = []
  property = schema.nodes
    .filter (x) -> x.parent is schema
    .map (node) ->
      if node.mandatory?.valueOf() is true
        required.push node.tag
      name: node.tag
      schema: yang2jschema node
  refs = schema.uses?.filter (x) -> x.parent is schema
  if refs?.length
    refs.forEach (ref) ->
      unless definitions[ref.tag]?
        debug? "[#{schema.trail}] defining #{ref.tag}"
        definitions[ref.tag] = true
        definitions[ref.tag] = yang2jsobj ref.state.grouping.origin
      
    if refs.length > 1 or property.length
      js.allOf = refs.map (ref) -> '$ref': "#/definitions/#{ref.tag}"
      if property.length
        js.allOf.push
          required: if required.length then required else undefined
          property: property
    else
      ref = refs[0]
      js['$ref'] = "#/definitions/#{ref.tag}"
  else
    js.type = 'object'
    js.required = required if required.length
    js.property = property if property.length
  
  return js

yang2jschema = (schema, item=false) ->
  return {} unless schema?
  switch schema.kind
    when 'leaf'      then yang2jstype schema
    when 'leaf-list' then type: 'array', items: yang2jstype schema
    when 'list'
      unless item then type: 'array', items: yang2jsobj schema
      else yang2jsobj schema
    when 'grouping' then {}
    else yang2jsobj schema

discoverOperations = (schema, item=false) ->
  debug? "[#{schema.trail}] discovering operations"
  deprecated = schema.status?.valueOf() is 'deprecated'
  switch 
    when schema.kind is 'rpc' then [
      method: 'post'
      summary: "Invokes #{schema.tag} in #{schema.parent.tag}."
      deprecated: deprecated
      response: [
        code: 200
        schema: yang2jschema schema.output
      ]
    ]
    when schema.kind is 'list' and not item then [
      method: 'post'
      summary: "Creates one or more new #{schema.tag} in #{schema.parent.tag}."
      deprecated: deprecated
      response: [
        code: 200
        description: "Expected response for creating #{schema.tag}(s) in collection"
        schema: yang2jschema schema
      ]
     ,
      method: 'get'
      description: schema.description
      summary: "List all #{schema.tag}s from #{schema.parent.tag}"
      deprecated: deprecated
      response: [
        code: 200
        description: "Expected response of #{schema.tag}s"
        schema: yang2jschema schema
      ]
     ,
      method: 'put'
      summary: "Replace the entire #{schema.tag} collection"
      deprecated: deprecated
      response: [
        code: 201
        description: "Expected response for replacing collection"
      ]
     ,
      method: 'patch'
      summary: "Merge items into the #{schema.tag} collection"
      deprecated: deprecated
      response: [
        code: 201
        description: "Expected response for merging into collection"
      ]
    ]
    else [
      method: 'get'
      description: schema.description
      summary: "View detail on #{schema.tag}"
      deprecated: deprecated
      response: [
        code: 200
        description: "Expected response of #{schema.tag}"
        schema: yang2jschema schema, item
      ]
     ,
      method: 'put'
      summary: "Update details on #{schema.tag}"
      deprecated: deprecated
      response: [
        code: 200
        description: "Expected response of #{schema.tag}"
        schema: yang2jschema schema, item
      ]
     ,
      method: 'patch'
      summary: "Merge details on #{schema.tag}"
      deprecated: deprecated
      response: [
        code: 200
        description: "Expected response of #{schema.tag}"
        schema: yang2jschema schema, item
      ]
     ,
      method: 'delete'
      summary: "Delete #{schema.tag} from #{schema.parent.tag}."
      deprecated: deprecated
      response: [
        code: 204
        description: "Expected response for delete"
      ]
    ]

discoverPaths = (schema) ->
  return [] unless schema.kind in [ 'list', 'container', 'rpc' ]
  name = "/#{schema.datakey}"
  debug? "[#{schema.trail}] discovering paths"
  paths = [
    name: name
    operation: discoverOperations schema
  ]
  subpaths = [].concat (discoverPaths sub for sub in schema.nodes)...
  switch schema.kind
    when 'list'
      key = schema.key?.valueOf() ? 'id'
      paths.push
        name: "#{name}/{#{key}}"
        operations: discoverOperations(schema,true)
      subpaths.forEach (x) -> x.name = "#{name}/{#{key}}" + x.name
    when 'container'
      subpaths.forEach (x) -> x.name = name + x.name
  debug? "[#{schema.trail}] discovered #{paths.length} paths with #{subpaths.length} subpaths"
  paths.concat subpaths...

serializeJSchema = (jschema) ->
  return unless jschema?
  o = {}
  o[k] = v for k, v of jschema when k isnt 'property'
  o.properties = jschema.property?.reduce ((a, _prop) ->
    a[_prop.name] = serializeJSchema _prop.schema
    return a
  ), {}
  o.items = serializeJSchema o.items
  o.allOf = o.allOf?.map (x) -> serializeJSchema x
  o.anyOf = o.anyOf?.map (x) -> serializeJSchema x
  o.oneOf = o.oneOf?.map (x) -> serializeJSchema x
  return o

module.exports = require('./yang-openapi.yang').bind {

  transform: ->
    modules = @input.modules.map (name) => @schema.constructor.import(name)
    debug? "transforming #{@input.modules} into yang-openapi"
    definitions = {} # usage of globals is a hack
    @output =
      swagger: '2.0'
      info: @get('/info')
      consumes: [ "application/json" ]
      produces: [ "application/json" ]
      path: modules
        .map (m) -> discoverPaths(schema) for schema in m.nodes
        .reduce ((a,b) -> a.concat b...), []
      definition: (name: k, schema: v for k, v of definitions)

  serialize: ->
    debug? "serializing yang-openapi spec"
    spec = clone @input.spec
    spec.paths = spec.path.reduce ((a,_path) ->
      path = a[_path.name] = '$ref': _path['$ref']
      for op in _path.operation
        operation = path[op.method] = {}
        operation[k] = v for k, v of op when k isnt 'response'
        operation.responses = op.response.reduce ((x,_res) ->
          x[_res.code] =
            description: _res.description
            schema: serializeJSchema _res.schema
          return x
        ), {}
      return a
    ), {}
    spec.definitions = spec.definition.reduce ((a,_def) ->
      a[_def.name] = serializeJSchema _def.schema
      return a
    ), {}
    delete spec.path
    delete spec.definition
    spec = traverse(spec).map (x) -> @remove() unless x?
    @output = switch @input.format
      when 'json' then JSON.stringify spec, null, 2
      when 'yaml' then yaml.dump spec
    
}
