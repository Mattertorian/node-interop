// Copyright (c) 2018, Anatoly Pulyaevskiy. All rights reserved. Use of this source code
// is governed by a BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:build_modules/build_modules.dart';
import 'package:build_node_compilers/src/common.dart';
import 'package:crypto/crypto.dart';
import 'package:node_preamble/preamble.dart';
import 'package:path/path.dart' as p;
import 'package:scratch_space/scratch_space.dart';

import 'node_entrypoint_builder.dart';
import 'platforms.dart';

Future<void> bootstrapDart2Js(
    BuildStep buildStep, List<String> dart2JsArgs) async {
  var dartEntrypointId = buildStep.inputId;
  var moduleId =
      dartEntrypointId.changeExtension(moduleExtension(dart2jsPlatform));
  var args = <String>[];
  {
    var module = Module.fromJson(
        json.decode(await buildStep.readAsString(moduleId))
            as Map<String, dynamic>);
    List<Module> allDeps;
    try {
      allDeps = (await module.computeTransitiveDependencies(
        buildStep,
        throwIfUnsupported: true,
      ))
        ..add(module);
    } on UnsupportedModules catch (e) {
      var librariesString = (await e.exactLibraries(buildStep).toList())
          .map((lib) => AssetId(lib.id.package,
              lib.id.path.replaceFirst(moduleLibraryExtension, '.dart')))
          .join('\n');
      log.warning('''
Skipping compiling ${buildStep.inputId} with dart2js because some of its
transitive libraries have sdk dependencies that not supported on this platform:

$librariesString

https://github.com/dart-lang/build/blob/master/docs/faq.md#how-can-i-resolve-skipped-compiling-warnings
''');
      return;
    }

    final scratchSpace = await buildStep.fetchResource(scratchSpaceResource);
    final allSrcs = allDeps.expand((module) => module.sources);
    await scratchSpace.ensureAssets(allSrcs, buildStep);
    // final packageFile =
    //     await _createPackageFile(allSrcs, buildStep, scratchSpace);

    // final dartPath = dartEntrypointId.path.startsWith('lib/')
    //     ? 'package:${dartEntrypointId.package}/'
    //         '${dartEntrypointId.path.substring('lib/'.length)}'
    //     : dartEntrypointId.path;

    final dartUri = dartEntrypointId.path.startsWith('lib/')
        ? Uri.parse('package:${dartEntrypointId.package}/'
            '${dartEntrypointId.path.substring('lib/'.length)}')
        : Uri.parse('$multiRootScheme:///${dartEntrypointId.path}');
    final librariesSpec = p.joinAll([sdkDir, 'lib', 'libraries.json']);
    // final jsOutputPath =
    //     '${p.withoutExtension(dartPath.replaceFirst('package:', 'packages/'))}'
    //     '$jsEntrypointExtension';
    final jsOutputPath = p.withoutExtension(dartUri.scheme == 'package'
            ? 'packages/${dartUri.path}'
            : dartUri.path.substring(1)) +
        jsEntrypointExtension;
    args = dart2JsArgs.toList()
      ..addAll([
        '--libraries-spec=$librariesSpec',
        '--packages=$multiRootScheme:///.dart_tool/package_config.json',
        '--multi-root-scheme=$multiRootScheme',
        '--multi-root=${scratchSpace.tempDir.uri.toFilePath()}',
        // for (var experiment in enabledExperiments)
        //   '--enable-experiment=$experiment',
        // if (nativeNullAssertions != null)
        //   '--${nativeNullAssertions ? '' : 'no-'}native-null-assertions',
        '-o$jsOutputPath',
        '$dartUri',
      ]);

    // args = dart2JsArgs.toList()
    //   ..addAll([
    //     '--packages=$packageFile',
    //     '-o=$jsOutputPath',
    //     dartPath,
    //   ]);
  }

  const _dart2jsVmArgsEnvVar = 'BUILD_DART2JS_VM_ARGS';

  final _dart2jsVmArgs = () {
    final env = Platform.environment[_dart2jsVmArgsEnvVar];
    return env?.split(' ') ?? <String>[];
  }();

  log.info('Running `dart compile js` with ${args.join(' ')}\n');
  // final dart2js = await buildStep.fetchResource(dart2JsWorkerResource);
  // final result = await dart2js.compile(args);
  final result = await Process.run(
    p.join(sdkDir, 'bin', 'dart'),
    [
      ..._dart2jsVmArgs,
      'compile',
      'js',
      ...args,
    ],
    workingDirectory: scratchSpace.tempDir.path,
  );
  final jsOutputId = dartEntrypointId.changeExtension(jsEntrypointExtension);
  final jsOutputFile = scratchSpace.fileFor(jsOutputId);
  // if (result.succeeded && await jsOutputFile.exists()) {
  //   log.info(result.output);
  if (result.exitCode == 0 && await jsOutputFile.exists()) {
    log.info('${result.stdout}\n${result.stderr}');
    addNodePreamble(jsOutputFile);

    await scratchSpace.copyOutput(jsOutputId, buildStep);
    var jsSourceMapId =
        dartEntrypointId.changeExtension(jsEntrypointSourceMapExtension);
    await _copyIfExists(jsSourceMapId, scratchSpace, buildStep);
  } else {
    log.severe('ExitCode:${result.exitCode}\nStdOut:\n${result.stdout}\n'
        'StdErr:\n${result.stderr}');
  }
}

Future<void> _copyIfExists(
    AssetId id, ScratchSpace scratchSpace, AssetWriter writer) async {
  var file = scratchSpace.fileFor(id);
  if (await file.exists()) {
    await scratchSpace.copyOutput(id, writer);
  }
}

void addNodePreamble(File output) {
  // var preamble = getPreamble(minified: true);
  var preamble = getPreamble(minified: false);
  var contents = output.readAsStringSync();
  output
    ..writeAsStringSync(preamble)
    ..writeAsStringSync(contents, mode: FileMode.append);
}

/// Creates a `.packages` file unique to this entrypoint at the root of the
/// scratch space and returns it's filename.
///
/// Since multiple invocations of Dart2Js will share a scratch space and we only
/// know the set of packages involved the current entrypoint we can't construct
/// a `.packages` file that will work for all invocations of Dart2Js so a unique
/// file is created for every entrypoint that is run.
///
/// The filename is based off the MD5 hash of the asset path so that files are
/// unique regardless of situations like `web/foo/bar.dart` vs
/// `web/foo-bar.dart`.
Future<String> _createPackageFile(Iterable<AssetId> inputSources,
    BuildStep buildStep, ScratchSpace scratchSpace) async {
  var inputUri = buildStep.inputId.uri;
  var packageFileName =
      '.package-${md5.convert(inputUri.toString().codeUnits)}';
  var packagesFile =
      scratchSpace.fileFor(AssetId(buildStep.inputId.package, packageFileName));
  var packageNames = inputSources.map((s) => s.package).toSet();
  var packagesFileContent =
      packageNames.map((n) => '$n:packages/$n/').join('\n');
  // await packagesFile
  //     .writeAsString('# Generated for $inputUri\n$packagesFileContent');
  await packagesFile.writeAsString(packagesFileContent);
  log.info('.package content: \n$packagesFileContent');
  return packageFileName;
}
