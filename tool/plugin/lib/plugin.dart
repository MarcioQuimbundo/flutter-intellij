// Copyright 2017 The Chromium Authors. All rights reserved. Use of this source
// code is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:git/git.dart';
import 'package:path/path.dart' as p;

import 'src/lint.dart';

main(List<String> args) async {
  BuildCommandRunner runner = new BuildCommandRunner();

  runner.addCommand(new LintCommand(runner));
  runner.addCommand(new AntBuildCommand(runner));
  runner.addCommand(new BuildCommand(runner));
  runner.addCommand(new TestCommand(runner));
  runner.addCommand(new DeployCommand(runner));
  runner.addCommand(new GenCommand(runner));

  try {
    exit(await runner.run(args) ?? 0);
  } on UsageException catch (e) {
    print('$e');
    exit(1);
  }
}

const plugins = const {
  'io.flutter': '9212',
  'io.flutter.as': '10139', // Currently unused.
};

String rootPath;

void addProductFlags(ArgParser argParser, String verb) {
  argParser.addFlag('ij', help: '$verb the IntelliJ plugin', defaultsTo: true);
  argParser.addFlag('as',
      help: '$verb the Android Studio plugin', defaultsTo: true);
}

Future<int> ant(BuildSpec spec) async {
  var args = new List<String>();
  String directory = null;
  args.add('-Ddart.plugin.version=${spec.dartPluginVersion}');
  args.add('-Didea.version=${spec.ideaVersion}');
  args.add('-Didea.product=${spec.ideaProduct}');
  args.add('-DSINCE=${spec.sinceBuild}');
  args.add('-DUNTIL=${spec.untilBuild}');
  // TODO(messick) Add version to plugin.xml.template.
  return await exec('ant', args, cwd: directory);
}

void copyResources({String from, String to}) {
  log('copying resources from $from to $to');
  _copyResources(new Directory(from), new Directory(to));
}

List<BuildSpec> createBuildSpecs(ProductCommand command) {
  var contents =
      new File(p.join(rootPath, 'product-matrix.json')).readAsStringSync();
  var map = JSON.decode(contents);
  var specs = new List<BuildSpec>();
  List input = map['list'];
  input.forEach((json) {
    specs.add(new BuildSpec.fromJson(json, command.release));
  });
  return specs;
}

void createDir(String name) {
  final Directory dir = new Directory(name);
  if (!dir.existsSync()) {
    log('creating $name/');
    dir.createSync(recursive: true);
  }
}

Future<int> curl(String url, {String to}) async {
  return await exec('curl', ['-o', to, url]);
}

Future<int> deleteBuildContents() async {
  final Directory dir = new Directory(p.join(rootPath, 'build'));
  if (!dir.existsSync()) throw 'No build directory found';
  var args = new List<String>();
  args.add('-rf');
  args.add(p.join(rootPath, 'build', '*'));
  return await exec('rm', args);
}

Future<int> exec(String cmd, List<String> args, {String cwd}) async {
  if (cwd != null) {
    log(_shorten('$cmd ${args.join(' ')} {cwd=$cwd}'));
  } else {
    log(_shorten('$cmd ${args.join(' ')}'));
  }

  final Process process = await Process.start(cmd, args, workingDirectory: cwd);
  _toLineStream(process.stderr, SYSTEM_ENCODING).listen(log);
  _toLineStream(process.stdout, SYSTEM_ENCODING).listen(log);

  return await process.exitCode;
}

List<File> findJars(String path) {
  final Directory dir = new Directory(path);
  return dir
      .listSync(recursive: true, followLinks: false)
      .where((e) => e.path.endsWith('.jar'))
      .toList();
}

List<String> findJavaFiles(String path) {
  final Directory dir = new Directory(path);
  return dir
      .listSync(recursive: true, followLinks: false)
      .where((e) => e.path.endsWith('.java'))
      .map((f) => f.path)
      .toList();
}

Future<int> genPluginXml(BuildSpec spec, String destDir) async {
  var file = await new File(p.join(rootPath, destDir, 'META-INF/plugin.xml'))
      .create(recursive: true);
  var dest = file.openWrite();
  // TODO(devoncarew): Move the change log to a separate file and insert it here.
  await new File(p.join(rootPath, 'resources/META-INF/plugin.xml.template'))
      .openRead()
      .transform(UTF8.decoder)
      .transform(new LineSplitter())
      .forEach((l) => dest.writeln(substitueTemplateVariables(l, spec)));
  await dest.close();
  return dest.done;
}

Future<int> jar(String directory, String outFile) async {
  List<String> args = ['cf', p.absolute(outFile)];
  args.addAll(new Directory(directory)
      .listSync(followLinks: false)
      .map((f) => p.basename(f.path)));
  args.remove('.DS_Store');
  return await exec('jar', args, cwd: directory);
}

void log(String s, {bool indent: true}) {
  indent ? print('  $s') : print(s);
}

Future<int> moveToArtifacts(ProductCommand cmd, BuildSpec spec) async {
  final Directory dir = new Directory(p.join(rootPath, 'artifacts'));
  if (!dir.existsSync()) throw 'No artifacts directory found';
  String file = plugins[spec.pluginId];
  var args = new List<String>();
  args.add(p.join(rootPath, 'build', file));
  args.add(cmd.archiveFilePath(spec));
  return await exec('mv', args);
}

Future<bool> performReleaseChecks(ProductCommand cmd) async {
  // git must have a release_NN branch where NN is the value of --release
  // git must have no uncommitted changes
  var isGitDir = await GitDir.isGitDir(rootPath);
  if (isGitDir) {
    if (cmd.isTestMode) {
      return new Future(() => true);
    }
    var gitDir = await GitDir.fromExisting(rootPath);
    var isClean = await gitDir.isWorkingTreeClean();
    if (isClean) {
      var branch = await gitDir.getCurrentBranch();
      String name = branch.branchName;
      var result = name == "release_${cmd.release}";
      if (result) {
        return new Future(() => result);
      } else {
        log('the current git branch must be named "$name"');
      }
    } else {
      log('the current git branch has uncommitted changes');
    }
  } else {
    log('the currect working directory is not managed by git: $rootPath');
  }
  return new Future(() => false);
}

Future<int> removeAll(String dir) async {
  var args = ['-rf', dir];
  return await exec('rm', args);
}

void separator(String name) {
  log('');
  log('$name:', indent: false);
}

String substitueTemplateVariables(String line, BuildSpec spec) {
  String valueOf(String name) {
    switch (name) {
      case 'PLUGINID':
        return spec.pluginId;
      case 'SINCE':
        return spec.sinceBuild;
      case 'UNTIL':
        return spec.untilBuild;
      default:
        throw 'unknown template variable: $name';
    }
  }

  int start = line.indexOf('@');
  while (start >= 0) {
    int end = line.indexOf('@', start + 1);
    var name = line.substring(start + 1, end);
    line = line.replaceRange(start, end + 1, valueOf(name));
    if (end < line.length - 1) {
      start = line.indexOf('@', end + 1);
    }
  }
  return line;
}

Future<int> zip(String directory, String outFile) async {
  var dest = p.absolute(outFile);
  createDir(p.dirname(dest));
  List<String> args = ['-r', dest, p.basename(directory)];
  return await exec('zip', args, cwd: p.dirname(directory));
}

void _copyFile(File file, Directory to) {
  if (!to.existsSync()) {
    to.createSync(recursive: true);
  }
  final File target = new File(p.join(to.path, p.basename(file.path)));
  target.writeAsBytesSync(file.readAsBytesSync());
}

void _copyResources(Directory from, Directory to) {
  for (FileSystemEntity entity in from.listSync(followLinks: false)) {
    final String basename = p.basename(entity.path);
    if (basename.endsWith('.java') ||
        basename.endsWith('.kt') ||
        basename.endsWith('.form') ||
        basename == 'plugin.xml.template') {
      continue;
    }

    if (entity is File) {
      _copyFile(entity, to);
    } else {
      _copyResources(entity, new Directory(p.join(to.path, basename)));
    }
  }
}

String _shorten(String s) {
  if (s.length < 200) {
    return s;
  }
  return s.substring(0, 170) + ' ... ' + s.substring(s.length - 30);
}

Stream<String> _toLineStream(Stream<List<int>> s, Encoding encoding) =>
    s.transform(encoding.decoder).transform(const LineSplitter());

/// Temporary command to use the Ant build script.
class AntBuildCommand extends ProductCommand {
  final BuildCommandRunner runner;

  AntBuildCommand(this.runner);

  String get description => 'Build a deployable version of the Flutter plugin, '
      'compiled against the specified artifacts.';

  String get name => 'abuild';

  Future<int> doit() async {
    if (isReleaseMode) {
      if (!await performReleaseChecks(this)) {
        return new Future(() => 1);
      }
    }
    var value;
    for (var spec in specs) {
      await spec.artifacts.provision(); // Not needed for ant script.
      await deleteBuildContents();
      value = await ant(spec);
      if (value != 0) {
        return value;
      }
      value = await moveToArtifacts(this, spec);
    }
    return value;
  }
}

class Artifact {
  final String file;
  final bool bareArchive;
  String output;

  Artifact(this.file, {this.bareArchive: false, this.output}) {
    if (output == null) {
      output = file.substring(0, file.lastIndexOf('-'));
    }
  }

  bool get isZip => file.endsWith('.zip');

  String get outPath => p.join(rootPath, 'artifacts', output);
}

class ArtifactManager {
  final String base =
      'https://storage.googleapis.com/flutter_infra/flutter/intellij';

  final List<Artifact> artifacts = [];

  Artifact javac;

  ArtifactManager() {
    javac = add(new Artifact(
      'intellij-javac2.zip',
      output: 'javac2',
      bareArchive: true,
    ));
  }

  Artifact add(Artifact artifact) {
    artifacts.add(artifact);
    return artifact;
  }

  Future<int> provision() async {
    separator('Getting artifacts');
    createDir('artifacts');

    int result = 0;
    for (Artifact artifact in artifacts) {
      final String path = 'artifacts/${artifact.file}';
      if (FileSystemEntity.isFileSync(path)) {
        log('$path exists in cache');
        continue;
      }

      log('downloading $path...');
      result = await curl('$base/${artifact.file}', to: path);
      if (result != 0) {
        log('download failed');
        break;
      }

      // expand
      createDir(artifact.outPath);

      if (artifact.isZip) {
        if (artifact.bareArchive) {
          result = await exec(
              'unzip', ['-q', '-d', artifact.output, artifact.file],
              cwd: 'artifacts');
        } else {
          result = await exec('unzip', ['-q', artifact.file], cwd: 'artifacts');
        }
      } else {
        result = await exec(
          'tar',
          [
            '--strip-components=1',
            '-zxf',
            artifact.file,
            '-C',
            artifact.output
          ],
          cwd: p.join(rootPath, 'artifacts'),
        );
      }
      if (result != 0) {
        log('unpacking failed');
        break;
      }

      log('');
    }
    return new Future(() => result);
  }
}

/// Build deployable plugin files. If the --release argument is given
/// then perform additional checks to verify that the release environment
/// is in good order.
class BuildCommand extends ProductCommand {
  final BuildCommandRunner runner;

  BuildCommand(this.runner);

  String get description => 'Build a deployable version of the Flutter plugin, '
      'compiled against the specified artifacts.';

  String get name => 'build';

  Future<int> doit() async {
    if (isReleaseMode) {
      if (!await performReleaseChecks(this)) {
        return new Future(() => 1);
      }
    }
    int result = 0;
    for (var spec in specs) {
      result = await spec.artifacts.provision();
      if (result != 0) {
        return new Future(() => result);
      }

      separator('Building flutter-intellij.jar');
      removeAll('build');
      result = await runner.javac2(spec);
      if (result != 0) {
        return new Future(() => result);
      }

      // copy resources
      copyResources(from: 'src', to: 'build/classes');
      copyResources(from: 'resources', to: 'build/classes');
      copyResources(from: 'gen', to: 'build/classes');
      copyResources(
          from: 'third_party/intellij-plugins-dart/src', to: 'build/classes');
      await genPluginXml(spec, 'build/classes');

      // create the jars
      createDir('build/flutter-intellij/lib');
      result = await jar(
          'build/classes', 'build/flutter-intellij/lib/flutter-intellij.jar');
      if (result != 0) {
        log('jar failed: ${result.toString()}');
        return new Future(() => result);
      }
      if (spec.isAndroidStudio) {
        result = await jar(
            'build/studio', 'build/flutter-intellij/lib/flutter-studio.jar');
        if (result != 0) {
          log('jar failed: ${result.toString()}');
          return new Future(() => result);
        }
      }

      // zip it up
      result = await zip('build/flutter-intellij', archiveFilePath(spec));
      if (result != 0) {
        log('zip failed: ${result.toString()}');
        return new Future(() => result);
      }
      break; //TODO remove
    }
    return 0;
  }
}

class BuildCommandRunner extends CommandRunner {
  BuildCommandRunner()
      : super('plugin',
            'A script to build, test, and deploy the Flutter IntelliJ plugin.') {
    argParser.addOption(
      'release',
      abbr: 'r',
      help: 'The release identifier; the numeric suffix of the git branch name',
      valueHelp: 'id',
    );
    argParser.addOption(
      'cwd',
      abbr: 'd',
      help: 'For testing only; the prefix used to locate the root path (../..)',
      valueHelp: 'relative-path',
    );
  }

  // Use this to compile test code, which should not define forms.
  Future<int> javac(
      {List sourcepath,
      String destdir,
      List classpath,
      List<String> sources}) async {
    //final Directory javacDir = new Directory('artifacts/${artifacts.javac.output}');

    final List<String> args = [
      '-d',
      destdir,
      '-encoding',
      'UTF-8',
      '-source',
      '8',
      '-target',
      '8',
      '-classpath',
      classpath.join(':'),
      '-sourcepath',
      sourcepath.join(':'),
    ];
    args.addAll(sources);

    return await exec('javac', args);
  }

  // Use this to compile plugin sources to get forms processed.
  Future<int> javac2(BuildSpec spec) async {
    String args = '''
-f tool/plugin/compile.xml
-Didea.product=${spec.ideaProduct}
-Didea.version=${spec.ideaVersion}
-Dbasedir=$rootPath
compile
''';
    return await exec('ant', args.split(new RegExp(r'\s')));
  }
}

class BuildSpec {
  // Build targets
  final String name;
  final String version;
  final String ideaProduct;
  final String ideaVersion;
  final String dartPluginVersion;

  // plugin.xml variables
  final String sinceBuild;
  final String untilBuild;
  final String pluginId = 'io.flutter';
  final String release;

  ArtifactManager artifacts = new ArtifactManager();

  Artifact product;
  Artifact dartPlugin;

  BuildSpec.fromJson(Map json, String releaseNum)
      : release = releaseNum,
        name = json['name'],
        version = json['version'],
        ideaProduct = json['ideaProduct'],
        ideaVersion = json['ideaVersion'],
        dartPluginVersion = json['dartPluginVersion'],
        sinceBuild = json['sinceBuild'],
        untilBuild = json['untilBuild'];

  bool get isAndroidStudio => ideaProduct.contains('android-studio');

  bool get isReleaseMode => release != null;

  createArtifacts() {
    if (ideaProduct == 'android-studio-ide') {
      product = artifacts.add(new Artifact(
          '$ideaProduct-$ideaVersion-linux.zip',
          output: ideaProduct));
    } else {
      product = artifacts.add(new Artifact('$ideaProduct-$ideaVersion.tar.gz',
          output: ideaProduct));
    }
    dartPlugin = artifacts.add(new Artifact('Dart-$dartPluginVersion.zip'));
  }

  String toString() {
    return 'BuildSpec($ideaProduct $ideaVersion $dartPluginVersion $sinceBuild '
        '$untilBuild version: "$release")';
  }
}

/// Prompt for the JetBrains account password then upload
/// the plugin distribution files to the JetBrains site.
/// The --release argument is not optional.
class DeployCommand extends ProductCommand {
  final BuildCommandRunner runner;
  String username;
  String tempDir;

  DeployCommand(this.runner);

  String get description => 'Upload the Flutter plugin to the JetBrains site.';

  String get name => 'deploy';

  Future<int> doit() async {
    if (isReleaseMode) {
      if (!await performReleaseChecks(this)) {
        return new Future(() => 1);
      }
    } else {
      log('Deploy must have a --release argument');
      return new Future(() => 1);
    }
    String password;
    try {
      // Detect test mode early to keep stdio clean for the test results parser.
      bool mode = stdin.echoMode;
      stdout.writeln(
          'Please enter the username and password for the JetBrains plugin repository');
      stdout.write('Username: ');
      username = stdin.readLineSync();
      stdout.write('Password: ');
      stdin.echoMode = false;
      password = stdin.readLineSync();
      stdin.echoMode = mode;
    } on StdinException {
      password = "hello"; // For testing.
      username = "test";
    }

    Directory directory = Directory.systemTemp.createTempSync('plugin');
    tempDir = directory.path;
    var file = new File('$tempDir/.content');
    file.writeAsStringSync(password, flush: true);

    var value = 0;
    try {
      for (var spec in specs) {
        String filePath = archiveFilePath(spec);
        value = await upload(filePath, plugins[spec.pluginId]);
        if (value != 0) {
          return value;
        }
      }
    } finally {
      file.deleteSync();
      directory.deleteSync();
    }
    return value;
  }

  Future<int> upload(String filePath, String pluginNumber) async {
    if (!new File(filePath).existsSync()) {
      throw 'File not found: $filePath';
    }
    log("uploading $filePath");
    String args = '''
-i 
-F userName="${username}" 
-F password="<${tempDir}/.content" 
-F pluginId="$pluginNumber" 
-F file="@$filePath" 
"https://plugins.jetbrains.com/plugin/uploadPlugin"
''';

    final Process process =
        await Process.start('curl', args.split(new RegExp(r'\s')));
    var result = await process.exitCode;
    if (result != 0) {
      log('Upload failed: ${result.toString()} for file: $filePath');
    }
    return result;
  }
}

/// Generate the plugin.xml from the plugin.xml.template file.
/// If the --release argument is given, create a git branch and
/// commit the new file to it, assuming the release checks pass.
class GenCommand extends Command {
  final BuildCommandRunner runner;

  GenCommand(this.runner);

  String get description =>
      'Generate a valid plugin.xml and .travis.yaml for the Flutter plugin.\n'
      'The plugin.xml.template and product-matrix.json are used as input.';

  String get name => 'gen';

  Future<int> run() async {
    // TODO(messick): Implement GenCommand.
    throw 'unimplemented';
  }
}

abstract class ProductCommand extends Command {
  List<BuildSpec> specs;

  ProductCommand() {
    addProductFlags(argParser, name[0].toUpperCase() + name.substring(1));
  }

  bool get isForAndroidStudio => argResults['as'];

  bool get isForIntelliJ => argResults['ij'];

  bool get isReleaseMode => release != null;

  bool get isTestMode => globalResults['cwd'] != null;

  String get release {
    var rel = globalResults['release'];
    if (rel != null && rel.startsWith('=')) {
      rel = rel.substring(1);
    }
    return rel;
  }

  String archiveFilePath(BuildSpec spec) {
    String subDir = isReleaseMode ? 'release_$release' : '';
    String filePath = p.join(
        rootPath, 'artifacts', subDir, spec.version, 'flutter-intellij.zip');
    return filePath;
  }

  Future<int> doit();

  Future<int> run() async {
    rootPath = Directory.current.path;
    var rel = globalResults['cwd'];
    if (rel != null) {
      rootPath = p.normalize(p.join(rootPath, rel));
    }
    specs = createBuildSpecs(this);
    return await doit();
  }
}

/// Build the tests if necessary then
/// run them and return any failure code.
class TestCommand extends ProductCommand {
  final BuildCommandRunner runner;

  TestCommand(this.runner) {
    argParser.addFlag('unit',
        abbr: 'u', defaultsTo: true, help: 'Run unit tests');
    argParser.addFlag('integration',
        abbr: 'i', defaultsTo: false, help: 'Run integration tests');
  }

  String get description => 'Run the tests for the Flutter plugin.';

  String get name => 'test';

  Future<int> doit() async {
    if (isReleaseMode) {
      if (!await performReleaseChecks(this)) {
        return new Future(() => 1);
      }
    }

    for (var spec in specs) {
      await spec.artifacts.provision();

      // TODO(messick) Finish the implementation of TestCommand.
      separator('Compiling test sources');

      List<File> jars = []
        ..addAll(findJars('${spec.dartPlugin.outPath}/lib'))
        ..addAll(
            findJars('${spec.product.outPath}/lib')); // TODO: also, plugins

      List<String> sourcepath = [
        'testSrc',
        'resources',
        'gen',
        'third_party/intellij-plugins-dart/testSrc'
      ];
      createDir('build/classes');

      await runner.javac(
        sources: sourcepath.expand(findJavaFiles).toList(),
        sourcepath: sourcepath,
        destdir: 'build/classes',
        classpath: jars.map((j) => j.path).toList(),
      );
    }
    throw 'unimplemented';
  }
}