import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:build/build.dart';
import 'package:build_runner_core/build_runner_core.dart';
import 'package:dart2ts/src/code_generator.dart';
import 'package:build/src/builder/build_step_impl.dart';
import 'package:path/path.dart' as p;
import 'package:build_resolvers/build_resolvers.dart';
import 'package:dart2ts/src/parts/contexts.dart';

final p.Context path = p.url;

npm([List<String> args = const ['run', 'build']]) async {
  Process npm = await Process.start('npm', args);
  stdout.addStream(npm.stdout);
  stderr.addStream(npm.stderr);
  int exitCode = await npm.exitCode;
  if (exitCode != 0) {
    throw "Build error";
  }
}

tsc({String basePath: '.'}) async {
  Process npm =
      await Process.start('npm run build', [], workingDirectory: basePath);
  stdout.addStream(npm.stdout);
  stderr.addStream(npm.stderr);
  int exitCode = await npm.exitCode;
  if (exitCode != 0) {
    throw "Build error";
  }
}

enum Mode { APPLICATION, LIBRARY }

class BuildException {
  BuildResult _result;

  BuildException(this._result);

  BuildResult get result => _result;

  toString() => "Build Exception ${_result.toString()}";
}

Future<BuildResult> tsbuild(
    {String basePath: '.', bool clean: true, Mode mode: Mode.LIBRARY}) async {
  if (clean) {
    Directory dir = new Directory(path.join(basePath, '.dart_tool'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  

  Config cfg;

  switch (mode) {
    case Mode.LIBRARY:
      cfg = new Config(modulePrefix: 'node_modules');
      break;
    case Mode.APPLICATION:
      cfg = new Config();
      break;
  }
  PackageGraph packageGraph = PackageGraph.fromRoot(PackageNode(null, basePath, null, null, isRoot: true));
  var builder = new Dart2TsBuilder(cfg);
  var resourceManager = ResourceManager();
  // var reader = StubAssetReader();
  var reader = new FileBasedAssetReader(packageGraph);
  var writer = new FileBasedAssetWriter(packageGraph);
  var primary = AssetId(packageGraph.root.name, packageGraph.root.path);
  var buildStep = BuildStepImpl(primary, [], reader, writer, primary.package,
      AnalyzerResolvers(), resourceManager);
  // build(actions, packageGraph: graph, onLog: (_) {}, deleteFilesByDefault: true);

  BuildResult res = await builder.build(buildStep);

  if (res.status != BuildStatus.success) {
    throw new BuildException(res);
  }

  await tsc(basePath: basePath);

  switch (mode) {
    case Mode.LIBRARY:
      await finishLibrary(
          basePath: basePath, packageName: packageGraph.root.name);
      break;
    case Mode.APPLICATION:
      break;
  }

  return res;
}

Future fixDependencyPath(String dist, String packageName) async {
  // Replace "node_modules" with relative url

  RegExp re = new RegExp("import([^\"']*)[\"']([^\"']*)[\"']");
  await for (FileSystemEntity f in new Directory(dist).list(recursive: true)) {
    if (f is File) {
      List<String> lines = await f.readAsLines();
      IOSink sink = f.openWrite();
      lines.map((l) {
        Match m = re.matchAsPrefix(l);
        if (m != null && (!path.isAbsolute(m[2]) && !m[2].startsWith('.'))) {
          // String origPath = m[2];
          String virtualAbsolutePath = path.joinAll([
            "node_modules",
            packageName
          ]..addAll(path.split(path.relative(f.path, from: dist))));
          String virtualRelativePath =
              path.relative(m[2], from: virtualAbsolutePath);
          // Compute relative path from "virtual" directory "node_modules/<package>/current_path"

          l = "import${m[1]}'${virtualRelativePath}';";
        }

        return l;
      }).forEach((l) => sink.writeln(l));

      await sink.close();
    }
  }
}

Future copyAssets(String dist, {String basePath: '.'}) async {
  // Copy assets
  String srcPath = path.join(basePath, 'lib');

  await for (FileSystemEntity f
      in new Directory(srcPath).list(recursive: true)) {
    if (f is File && !f.path.endsWith('.dart') && !f.path.endsWith('.ts')) {
      File d = new File(path.join(dist, path.relative(f.path, from: srcPath)));
      if (!d.parent.existsSync()) {
        await d.parent.create(recursive: true);
      }
      await f.copy(d.path);
    }
  }
}

Future finishLibrary({String basePath: '.', String packageName}) async {
  File tsconfigFile = new File(path.join(basePath, 'tsconfig.json'));
  var tsconfig = jsonDecode(tsconfigFile.readAsStringSync());
  String dist =
      path.joinAll([basePath, tsconfig['compilerOptions']['outDir'], 'lib']);
  await fixDependencyPath(dist, packageName);
  await copyAssets(dist);
}
