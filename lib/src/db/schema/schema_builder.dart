import 'schema.dart';
import 'migration_builder.dart';
import '../persistent_store/persistent_store.dart';

/// Used during migration to modify a schema.
class SchemaBuilder {
  /// Creates a builder starting from an existing schema.
  SchemaBuilder(this.store, this.inputSchema, {this.isTemporary: false}) {
    schema = new Schema.from(inputSchema);
  }

  /// Creates a builder starting from the empty schema.
  SchemaBuilder.toSchema(this.store, Schema targetSchema,
      {this.isTemporary: false}) {
    schema = new Schema.empty();
    targetSchema.dependencyOrderedTables.forEach((t) {
      createTable(t);
    });
  }

  /// The starting schema of this builder.
  Schema inputSchema;

  /// The resulting schema of this builder as operations are applied to it.
  Schema schema;

  /// The persistent store to validate and construct operations.
  PersistentStore store;

  /// Whether or not this builder should create temporary tables.
  bool isTemporary;

  /// A list of SQL commands generated by operations performed on this builder.
  List<String> commands = [];

  /// Validates and adds a table to [schema].
  void createTable(SchemaTable table) {
    schema.addTable(table);

    if (store != null) {
      commands.addAll(store.createTable(table, isTemporary: isTemporary));
    }
  }

  /// Validates and renames a table in [schema].
  void renameTable(String currentTableName, String newName) {
    var table = schema.tableForName(currentTableName);
    if (table == null) {
      throw new SchemaException("Table ${currentTableName} does not exist.");
    }

    schema.renameTable(table, newName);
    if (store != null) {
      commands.addAll(store.renameTable(table, newName));
    }
  }

  /// Validates and deletes a table in [schema].
  void deleteTable(String tableName) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw new SchemaException("Table ${tableName} does not exist.");
    }

    schema.removeTable(table);

    if (store != null) {
      commands.addAll(store.deleteTable(table));
    }
  }

  /// Validates and adds a column to a table in [schema].
  void addColumn(String tableName, SchemaColumn column, {String unencodedInitialValue}) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw new SchemaException("Table ${tableName} does not exist.");
    }

    table.addColumn(column);
    if (store != null) {
      commands.addAll(store.addColumn(table, column, unencodedInitialValue: unencodedInitialValue));
    }
  }

  /// Validates and deletes a column in a table in [schema].
  void deleteColumn(String tableName, String columnName) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw new SchemaException("Table ${tableName} does not exist.");
    }

    var column = table.columnForName(columnName);
    if (column == null) {
      throw new SchemaException("Column ${columnName} does not exists.");
    }

    table.removeColumn(column);

    if (store != null) {
      commands.addAll(store.deleteColumn(table, column));
    }
  }

  /// Validates and renames a column in a table in [schema].
  void renameColumn(String tableName, String columnName, String newName) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw new SchemaException("Table ${tableName} does not exist.");
    }

    var column = table.columnForName(columnName);
    if (column == null) {
      throw new SchemaException("Column ${columnName} does not exists.");
    }

    table.renameColumn(column, newName);

    if (store != null) {
      commands.addAll(store.renameColumn(table, column, newName));
    }
  }

  /// Validates and alters a column in a table in [schema].
  ///
  /// Alterations are made by setting properties of the column passed to [modify]. If the column's nullability
  /// changes from nullable to not nullable,  all previously null values for that column
  /// are set to the value of [unencodedInitialValue].
  ///
  /// Example:
  ///
  ///         database.alterColumn("table", "column", (c) {
  ///           c.isIndexed = true;
  ///           c.isNullable = false;
  ///         }), unencodedInitialValue: "0");
  void alterColumn(String tableName, String columnName,
      void modify(SchemaColumn targetColumn),
      {String unencodedInitialValue}) {
    var table = schema.tableForName(tableName);
    if (table == null) {
      throw new SchemaException("Table ${tableName} does not exist.");
    }

    var existingColumn = table[columnName];
    if (existingColumn == null) {
      throw new SchemaException("Column ${columnName} does not exist.");
    }

    var newColumn = new SchemaColumn.from(existingColumn);
    modify(newColumn);

    if (existingColumn.type != newColumn.type) {
      throw new SchemaException(
          "May not change column (${existingColumn.name}) type (${existingColumn.typeString} -> ${newColumn.typeString})");
    }

    if (existingColumn.autoincrement != newColumn.autoincrement) {
      throw new SchemaException(
          "May not change column (${existingColumn.name}) autoincrementing behavior");
    }

    if (existingColumn.isPrimaryKey != newColumn.isPrimaryKey) {
      throw new SchemaException(
          "May not change column (${existingColumn.name}) to/from primary key");
    }

    if (existingColumn.relatedTableName != newColumn.relatedTableName) {
      throw new SchemaException(
          "May not change column (${existingColumn.name}) reference table (${existingColumn.relatedTableName} -> ${newColumn.relatedTableName})");
    }

    if (existingColumn.relatedColumnName != newColumn.relatedColumnName) {
      throw new SchemaException(
          "May not change column (${existingColumn.name}) reference column (${existingColumn.relatedColumnName} -> ${newColumn.relatedColumnName})");
    }

    if (existingColumn.name != newColumn.name) {
      renameColumn(tableName, existingColumn.name, newColumn.name);
    }

    if (existingColumn.isNullable == true &&
        newColumn.isNullable == false &&
        unencodedInitialValue == null &&
        newColumn.defaultValue == null) {
      throw new SchemaException(
          "May not change column (${existingColumn.name}) to be nullable without defaultValue or unencodedInitialValue.");
    }

    table.replaceColumn(existingColumn, newColumn);

    if (store != null) {
      if (existingColumn.isIndexed != newColumn.isIndexed) {
        if (newColumn.isIndexed) {
          commands.addAll(store.addIndexToColumn(table, newColumn));
        } else {
          commands.addAll(store.deleteIndexFromColumn(table, newColumn));
        }
      }

      if (existingColumn.isUnique != newColumn.isUnique) {
        commands.addAll(store.alterColumnUniqueness(table, newColumn));
      }

      if (existingColumn.defaultValue != newColumn.defaultValue) {
        commands.addAll(store.alterColumnDefaultValue(table, newColumn));
      }

      if (existingColumn.isNullable != newColumn.isNullable) {
        commands.addAll(store.alterColumnNullability(
            table, newColumn, unencodedInitialValue));
      }

      if (existingColumn.deleteRule != newColumn.deleteRule) {
        commands.addAll(store.alterColumnDeleteRule(table, newColumn));
      }
    }
  }

  /// Used internally.
  static String sourceForSchemaUpgrade(
      Schema existingSchema, Schema newSchema, int version, {List<String> changeList}) {
    var builder = new StringBuffer();
    builder.writeln("import 'package:aqueduct/aqueduct.dart';");
    builder.writeln("import 'dart:async';");
    builder.writeln("");
    builder.writeln("class Migration$version extends Migration {");
    builder.writeln("  Future upgrade() async {");

    var diff = existingSchema.differenceFrom(newSchema);

    // Grab tables from dependencyOrderedTables to reuse ordering behavior
    newSchema.dependencyOrderedTables
      .where((t) => diff.tableNamesToAdd.contains(t.name))
        .forEach((t) {
      builder.writeln(MigrationBuilder.createTableString(t, "    "));
    });

    existingSchema.dependencyOrderedTables.reversed
        .where((t) => diff.tableNamesToDelete.contains(t.name))
        .forEach((t) {
      builder.writeln(MigrationBuilder.deleteTableString(t.name, "    "));
    });

    diff.differingTables
        .where((tableDiff) => tableDiff.expectedTable != null && tableDiff.actualTable != null)
        .forEach((tableDiff) {
      tableDiff.columnNamesToAdd
          .forEach((columnName) {
        builder.writeln(MigrationBuilder.addColumnString(tableDiff.actualTable.name, tableDiff.actualTable.columnForName(columnName), "    "));
      });

      tableDiff.columnNamesToDelete
          .forEach((columnName) {
        builder.writeln(MigrationBuilder.deleteColumnString(tableDiff.actualTable.name, columnName, "    "));
      });

      tableDiff.differingColumns
        .where((columnDiff) => columnDiff.expectedColumn != null && columnDiff.actualColumn != null)
        .forEach((columnDiff) {
        builder.writeln(MigrationBuilder.alterColumnString(tableDiff.actualTable.name, columnDiff.expectedColumn, columnDiff.actualColumn, "    "));
      });
    });

    builder.writeln("  }");
    builder.writeln("");
    builder.writeln("  Future downgrade() async {");
    builder.writeln("  }");
    builder.writeln("  Future seed() async {");
    builder.writeln("  }");
    builder.writeln("}");

    return builder.toString();
  }
}
