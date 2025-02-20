part of 'cassandart_impl.dart';

abstract class Opcode {
  static const int error = 0x00;
  static const int start = 0x01;
  static const int ready = 0x02;
  static const int authenticate = 0x03;
  static const int options = 0x05;
  static const int supported = 0x06;
  static const int query = 0x07;
  static const int result = 0x08;
  static const int prepare = 0x09;
  static const int execute = 0x0A;
  static const int register = 0x0B;
  static const int event = 0x0C;
  static const int batch = 0x0D;
  static const int authChallenge = 0x0E;
  static const int authResponse = 0x0F;
  static const int authSuccess = 0x10;
}

class FrameProtocol {
  final protocolVersion = 4;
  final Sink<Frame> _requestSink;
  final Stream<Frame> _responseStream;
  final _responseCompleters = <int, Completer<Frame>>{};
  final _eventController = StreamController<Frame>();
  StreamSubscription<Frame>? _responseSubscription;

  FrameProtocol(this._requestSink, this._responseStream);

  Future<void> start(Authenticator authenticator) async {
    _responseSubscription = _responseStream.listen(_handleResponse);
    final rs = await send(Opcode.start,
        (_BodyWriter()..writeStringMap({'CQL_VERSION': '3.0.0'})).toBytes());
    if (rs.opcode == Opcode.ready) {
      return;
    }
    if (rs.opcode == Opcode.authenticate) {
      final reader = _BodyReader(rs.body);
      final className = reader.parseShortString();
      if (className == 'org.apache.cassandra.auth.PasswordAuthenticator') {
        final payload = await authenticator.respond(Uint8List(0));
        final body = _BodyWriter()..writeBytes(payload);
        final auth = await send(Opcode.authResponse, body.toBytes());
        _throwIfError(auth);
        if (auth.opcode == Opcode.authSuccess) {
          return;
        }
        throw UnimplementedError('Unimplemented auth handler: ${auth.opcode}');
      }
    }
    throw UnimplementedError('Unimplemented opcode handler: ${rs.opcode}');
  }

  Stream<Frame> get events => _eventController.stream;

  Future<Frame> send(int opcode, Uint8List body) async {
    if (_responseSubscription == null) {
      throw StateError('Connection is closed.');
    }
    final header = FrameHeader(
      isRequest: true,
      protocolVersion: protocolVersion,
      isCompressed: false,
      requiresTracing: false,
      hasCustomPayload: false,
      hasWarning: false,
      streamId: _nextStreamId(),
      opcode: opcode,
      length: body.length,
    );
    final frame = Frame(header, body);
    final c = Completer<Frame>();
    _responseCompleters[frame.header.streamId] = c;
    _requestSink.add(frame);
    return await c.future;
  }

  Future<void> execute(String query, Consistency? consistency, values) async {
    final body = buildQuery(
      query: query,
      consistency: consistency,
      values: values,
      pageSize: null,
      pagingState: null,
    );
    final rs = await send(Opcode.query, body);
    _throwIfError(rs);
    if (rs.opcode == Opcode.result) {
      final br = _BodyReader(rs.body);
      final int kind = br.parseInt();
      switch (kind) {
        case _ResultKind.void$:
          return;
        case _ResultKind.rows:
          throw UnimplementedError('Result kind $kind not supported.');
        case _ResultKind.setKeyspace:
          return;
        case _ResultKind.prepared:
          throw UnimplementedError('Result kind $kind not supported.');
        case _ResultKind.schemaChange:
          return;
        default:
          throw UnimplementedError('Result kind $kind not implemented.');
      }
    }
    throw UnimplementedError('Unimplemented opcode handler: ${rs.opcode}');
  }

  Future<ResultPage> query(Client client, _Query q, Uint8List body) async {
    final rs = await send(Opcode.query, body);
    _throwIfError(rs);
    if (rs.opcode == Opcode.result) {
      final br = _BodyReader(rs.body);
      List<String>? warnings;

      if (rs.header.hasWarning) {
        warnings = br.readStringList();
      }

      final int kind = br.parseInt();
      switch (kind) {
        case _ResultKind.void$:
          throw UnimplementedError('Result kind $kind not supported.');
        case _ResultKind.rows:
          return _parseRowsBody(client, q, br, warnings);
        case _ResultKind.setKeyspace:
          throw UnimplementedError('Result kind $kind not supported.');
        case _ResultKind.prepared:
          throw UnimplementedError('Result kind $kind not supported.');
        case _ResultKind.schemaChange:
          throw UnimplementedError('Result kind $kind not supported.');
        default:
          final resultCode = '0x${kind.toRadixString(16).padLeft(4, '0')}';
          throw UnimplementedError('Result kind $resultCode not implemented.');
      }
    }
    throw UnimplementedError('Unimplemented opcode handler: ${rs.opcode}');
  }

  Future<void> close() async {
    _requestSink.close();
    await _responseSubscription!.cancel();
    _responseSubscription = null;
    await _eventController.close();
  }

  int _nextStreamId() {
    for (int i = 0; i < 32768; i++) {
      if (!_responseCompleters.containsKey(i)) {
        return i;
      }
    }
    throw StateError('Unable to open a stream, maximum limit reached.');
  }

  void _handleResponse(Frame frame) {
    if (frame.streamId >= 0) {
      final completer = _responseCompleters.remove(frame.streamId);

      if (completer == null) {
        // TODO: log something is not right
        print('No stream for ${frame.streamId}');
      } else {
        completer.complete(frame);
      }
    } else {
      _eventController.add(frame);
    }
  }

  void _throwIfError(Frame frame) {
    if (frame.opcode == Opcode.error) {
      throw ErrorResponse.parse(frame.body);
    }
  }
}

class ErrorResponse implements Exception {
  final int code;
  final String message;

  ErrorResponse(this.code, this.message);

  factory ErrorResponse.parse(Uint8List body) {
    final br = _BodyReader(body);
    final code = br.parseInt();
    final message = br.parseShortString();
    return ErrorResponse(code, message);
  }

  @override
  String toString() => '[${code.toRadixString(16).padLeft(4, '0')}] $message';
}

abstract class _ResultKind {
  static const int void$ = 0x0001;
  static const int rows = 0x0002;
  static const int setKeyspace = 0x0003;
  static const int prepared = 0x0004;
  static const int schemaChange = 0x0005;
}

ResultPage _parseRowsBody(
  Client client,
  _Query q,
  _BodyReader br,
  List<String>? warnings,
) {
  final flags = br.parseInt();
  final hasGlobalTableSpec = flags & 0x0001 != 0;
  final hasMorePages = flags & 0x0002 != 0;
  // final hasNoMetadata = flags & 0x0004 != 0;
  final columnsCount = br.parseInt();
  Uint8List? pagingState;
  if (hasMorePages) {
    pagingState = br.parseBytes(copy: true);
  }
  String? globalKeyspace;
  String? globalTable;

  if (hasGlobalTableSpec) {
    globalKeyspace = br.parseShortString();
    globalTable = br.parseShortString();
  }
  final columns = <Column>[];
  for (int i = 0; i < columnsCount; i++) {
    String? keyspace = globalKeyspace;
    String? table = globalTable;

    if (!hasGlobalTableSpec) {
      keyspace = br.parseShortString();
      table = br.parseShortString();
    }

    final column = br.parseShortString();
    final valueType = _parseValueType(br);

    columns.add(Column(keyspace!, table!, column, valueType));
  }
  final rowsCount = br.parseInt();
  final rows = <_Row>[];
  for (int i = 0; i < rowsCount; i++) {
    final values = List<Object?>.filled(columnsCount, null);

    for (int j = 0; j < columnsCount; j++) {
      final bytes = br.parseBytes();
      values[j] = bytes == null ? null : decodeData(columns[j].type, bytes);
    }

    rows.add(_Row(columns, values));
  }

  return _RowsPage(
    client,
    q,
    columns,
    rows,
    !hasMorePages,
    pagingState,
    warnings,
  );
}

enum RawType {
  custom,
  ascii,
  bigint,
  blob,
  boolean,
  counter,
  decimal,
  double,
  float,
  int,
  timestamp,
  uuid,
  varchar,
  varint,
  timeuuid,
  inet,
  date,
  time,
  smallint,
  tinyint,
  list,
  map,
  set,
  udt,
  tuple,
}

const _rawTypeMap = <int, RawType>{
  0x0000: RawType.custom,
  0x0001: RawType.ascii,
  0x0002: RawType.bigint,
  0x0003: RawType.blob,
  0x0004: RawType.boolean,
  0x0005: RawType.counter,
  0x0006: RawType.decimal,
  0x0007: RawType.double,
  0x0008: RawType.float,
  0x0009: RawType.int,
  0x000B: RawType.timestamp,
  0x000C: RawType.uuid,
  0x000D: RawType.varchar,
  0x000E: RawType.varint,
  0x000F: RawType.timeuuid,
  0x0010: RawType.inet,
  0x0011: RawType.date,
  0x0012: RawType.time,
  0x0013: RawType.smallint,
  0x0014: RawType.tinyint,
  0x0020: RawType.list,
  0x0021: RawType.map,
  0x0022: RawType.set,
  0x0030: RawType.udt,
  0x0031: RawType.tuple,
};

class Type {
  final RawType rawType;

  /// String description of custom type
  final String? customTypeName;

  /// Generic type parameters:
  /// List, Set: one value
  /// Map: two values: key, value
  /// Tuples: N values
  final List<Type>? parameters;

  Type._(this.rawType, this.customTypeName, this.parameters);

  const Type(this.rawType, [this.parameters]) : customTypeName = null;
}

Type _parseValueType(_BodyReader br) {
  final typeCode = br.parseShort();
  final rawType = _rawTypeMap[typeCode];
  if (rawType == null) {
    throw UnimplementedError('Unknown type code: $typeCode');
  }
  switch (rawType) {
    case RawType.custom:
      final customType = br.parseShortString();
      return Type._(RawType.custom, customType, null);
    case RawType.ascii:
    case RawType.bigint:
    case RawType.blob:
    case RawType.boolean:
    case RawType.counter:
    case RawType.decimal:
    case RawType.double:
    case RawType.float:
    case RawType.int:
    case RawType.timestamp:
    case RawType.uuid:
    case RawType.varchar:
    case RawType.varint:
    case RawType.timeuuid:
    case RawType.inet:
    case RawType.date:
    case RawType.time:
    case RawType.smallint:
    case RawType.tinyint:
      return Type(rawType);
    case RawType.set:
      return Type(rawType, [_parseValueType(br)]);
    default:
      throw UnimplementedError('Unhandled raw type: $rawType');
  }
}

class Column {
  final String keyspace;
  final String table;
  final String column;
  final Type type;

  Column(this.keyspace, this.table, this.column, this.type);
}

abstract class Row {
  List<Column> get columns;
  List get values;
  Map<String, dynamic> asMap();
}

class _Row implements Row {
  @override
  final List<Column> columns;
  @override
  final List values;

  _Row(this.columns, this.values);

  @override
  Map<String, dynamic> asMap() {
    final map = <String, dynamic>{};
    for (int i = 0; i < columns.length; i++) {
      map[columns[i].column] = values[i];
    }
    return map;
  }
}

abstract class ResultPage implements Page<Row> {
  List<Column> get columns;
  Uint8List? get pagingState;
  List<Row> get rows => items;
  List<String>? get warnings;
  bool get hasWarnings;
}

class _Query {
  final String query;
  final Consistency? consistency;
  final dynamic values;
  final int? pageSize;
  final Uint8List? pagingState;

  _Query(
    this.query,
    this.consistency,
    this.values,
    this.pageSize,
    this.pagingState,
  );
}

class _RowsPage extends Object with PageMixin<Row>, ResultPage {
  final Client _client;
  final _Query _query;

  @override
  final List<Column> columns;

  @override
  final List<Row> items;

  @override
  final bool isLast;

  @override
  final Uint8List? pagingState;

  @override
  final List<String>? warnings;

  _RowsPage(this._client, this._query, this.columns, this.items, this.isLast,
      this.pagingState, this.warnings);

  @override
  Future<ResultPage> next() => _client.query(
      _query.query,
      consistency: _query.consistency,
      values: _query.values,
      pageSize: _query.pageSize,
      pagingState: pagingState,
    );

  @override
  Future<void> close() async {}

  @override
  bool get hasWarnings => warnings?.isNotEmpty == true;
}
