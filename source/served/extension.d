module served.extension;

import core.exception;
import core.thread : Fiber;
import core.sync.mutex;

import std.algorithm;
import std.array;
import std.conv;
import std.datetime.systime;
import std.datetime.stopwatch;
import fs = std.file;
import std.experimental.logger;
import std.functional;
import std.json;
import std.path;
import std.regex;
import io = std.stdio;
import std.string;
import rm.rf;

import served.ddoc;
import served.fibermanager;
import served.types;
import served.translate;

import workspaced.api;
import workspaced.com.dcd;
import workspaced.com.importer;
import workspaced.coms;

import served.linters.dub : DubDiagnosticSource;

/// Set to true when shutdown is called
__gshared bool shutdownRequested;

bool safe(alias fn, Args...)(Args args)
{
	try
	{
		fn(args);
		return true;
	}
	catch (Exception e)
	{
		error(e);
		return false;
	}
	catch (AssertError e)
	{
		error(e);
		return false;
	}
}

void changedConfig(string workspaceUri, string[] paths, served.types.Configuration config)
{
	StopWatch sw;
	sw.start();

	if (!syncedConfiguration)
	{
		syncedConfiguration = true;
		doGlobalStartup();
	}
	Workspace* proj = &workspace(workspaceUri);
	if (proj is &fallbackWorkspace)
	{
		error("Did not find workspace ", workspaceUri, " when updating config?");
		return;
	}
	if (!proj.initialized)
	{
		doStartup(proj.folder.uri);
		proj.initialized = true;
	}

	auto workspaceFs = workspaceUri.uriToFile;

	foreach (path; paths)
	{
		switch (path)
		{
		case "d.stdlibPath":
			backend.get!DCDComponent(workspaceFs).addImports(config.stdlibPath);
			break;
		case "d.projectImportPaths":
			backend.get!DCDComponent(workspaceFs).addImports(config.d.projectImportPaths);
			break;
		case "d.dubConfiguration":
			auto configs = backend.get!DubComponent(workspaceFs).configurations;
			if (configs.length == 0)
				rpc.window.showInformationMessage(translate!"d.ext.noConfigurations.project");
			else
			{
				auto defaultConfig = config.d.dubConfiguration;
				if (defaultConfig.length)
				{
					if (!configs.canFind(defaultConfig))
						rpc.window.showErrorMessage(
								translate!"d.ext.config.invalid.configuration"(defaultConfig));
					else
						backend.get!DubComponent(workspaceFs).setConfiguration(defaultConfig);
				}
				else
					backend.get!DubComponent(workspaceFs).setConfiguration(configs[0]);
			}
			break;
		case "d.dubArchType":
			if (config.d.dubArchType.length && !backend.get!DubComponent(workspaceFs)
					.setArchType(JSONValue(["arch-type" : JSONValue(config.d.dubArchType)])))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.archType"(config.d.dubArchType));
			break;
		case "d.dubBuildType":
			if (config.d.dubBuildType.length && !backend.get!DubComponent(workspaceFs)
					.setBuildType(JSONValue(["build-type" : JSONValue(config.d.dubBuildType)])))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.buildType"(config.d.dubBuildType));
			break;
		case "d.dubCompiler":
			if (config.d.dubCompiler.length && !backend.get!DubComponent(workspaceFs)
					.setCompiler(config.d.dubCompiler))
				rpc.window.showErrorMessage(
						translate!"d.ext.config.invalid.compiler"(config.d.dubCompiler));
			break;
		default:
			break;
		}
	}

	trace("Finished config change of ", workspaceUri, " with ", paths.length,
			" changes in ", sw.peek, ".");
}

void processConfigChange(served.types.Configuration configuration)
{
	import painlessjson : fromJSON;

	if (capabilities.workspace.configuration && workspaces.length >= 2)
	{
		ConfigurationItem[] items;
		foreach (workspace; workspaces)
			foreach (section; configurationSections)
				items ~= ConfigurationItem(opt(workspace.folder.uri), opt(section));
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));
		if (res.result.type == JSON_TYPE.ARRAY)
		{
			JSONValue[] settings = res.result.array;
			if (settings.length % configurationSections.length != 0)
			{
				error("Got invalid configuration response from language client.");
				trace("Response: ", res);
				return;
			}
			for (size_t i = 0; i < settings.length; i += configurationSections.length)
			{
				string[] changed;
				static foreach (n, section; configurationSections)
					changed ~= workspaces[i / configurationSections.length].config.replaceSection!section(
							settings[i + n].fromJSON!(configurationTypes[n]));
				changedConfig(workspaces[i / configurationSections.length].folder.uri,
						changed, workspaces[i / configurationSections.length].config);
			}
		}
	}
	else if (workspaces.length)
	{
		if (workspaces.length > 1)
			error(
					"Client does not support configuration request, only applying config for first workspace.");
		served.extension.changedConfig(workspaces[0].folder.uri,
				workspaces[0].config.replace(configuration), workspaces[0].config);
	}
}

bool syncConfiguration(string workspaceUri)
{
	import painlessjson : fromJSON;

	if (capabilities.workspace.configuration)
	{
		Workspace* proj = &workspace(workspaceUri);
		if (proj is &fallbackWorkspace)
		{
			error("Did not find workspace ", workspaceUri, " when syncing config?");
			return false;
		}
		ConfigurationItem[] items;
		foreach (section; configurationSections)
			items ~= ConfigurationItem(opt(proj.folder.uri), opt(section));
		auto res = rpc.sendRequest("workspace/configuration", ConfigurationParams(items));
		if (res.result.type == JSON_TYPE.ARRAY)
		{
			JSONValue[] settings = res.result.array;
			if (settings.length % configurationSections.length != 0)
			{
				error("Got invalid configuration response from language client.");
				trace("Response: ", res);
				return false;
			}
			string[] changed;
			static foreach (n, section; configurationSections)
				changed ~= proj.config.replaceSection!section(
						settings[n].fromJSON!(configurationTypes[n]));
			changedConfig(proj.folder.uri, changed, proj.config);
			return true;
		}
		else
			return false;
	}
	else
		return false;
}

string[] getPossibleSourceRoots(string workspaceFolder)
{
	import std.file;

	auto confPaths = config(workspaceFolder.uriFromFile, false).d.projectImportPaths.map!(
			a => a.isAbsolute ? a : buildNormalizedPath(workspaceRoot, a));
	if (!confPaths.empty)
		return confPaths.array;
	auto a = buildNormalizedPath(workspaceFolder, "source");
	auto b = buildNormalizedPath(workspaceFolder, "src");
	if (exists(a))
		return [a];
	if (exists(b))
		return [b];
	return [workspaceFolder];
}

__gshared bool syncedConfiguration = false;
InitializeResult initialize(InitializeParams params)
{
	import std.file : chdir;

	capabilities = params.capabilities;
	trace("Set capabilities to ", params);

	if (params.workspaceFolders.length)
		workspaces = params.workspaceFolders.map!(a => Workspace(a,
				served.types.Configuration.init)).array;
	else if (params.rootPath.length)
		workspaces = [Workspace(WorkspaceFolder(params.rootPath.uriFromFile,
				"Root"), served.types.Configuration.init)];
	if (workspaces.length)
	{
		fallbackWorkspace.folder = workspaces[0].folder;
		fallbackWorkspace.initialized = true;
	}

	InitializeResult result;
	result.capabilities.textDocumentSync = documents.syncKind;
	result.capabilities.completionProvider = CompletionOptions(false, [".", "(", "[", "="]);
	result.capabilities.signatureHelpProvider = SignatureHelpOptions(["(", "[", ","]);
	result.capabilities.workspaceSymbolProvider = true;
	result.capabilities.definitionProvider = true;
	result.capabilities.hoverProvider = true;
	result.capabilities.codeActionProvider = true;
	result.capabilities.codeLensProvider = CodeLensOptions(true);
	result.capabilities.documentSymbolProvider = true;
	result.capabilities.documentFormattingProvider = true;
	result.capabilities.codeActionProvider = true;
	result.capabilities.workspace = opt(ServerWorkspaceCapabilities(
			opt(ServerWorkspaceCapabilities.WorkspaceFolders(opt(true), opt(true)))));

	setTimeout({
		if (!syncedConfiguration && capabilities.workspace.configuration)
			foreach (ref workspace; workspaces)
				syncConfiguration(workspace.folder.uri);
	}, 1000);

	return result;
}

void doGlobalStartup()
{
	try
	{
		trace("Initializing serve-d for global access");

		backend.globalConfiguration.base = JSONValue(["dcd" : JSONValue(["clientPath"
				: JSONValue(firstConfig.d.dcdClientPath), "serverPath"
				: JSONValue(firstConfig.d.dcdServerPath), "port" : JSONValue(9166)]),
				"dmd" : JSONValue(["path" : JSONValue(firstConfig.d.dmdPath)])]);

		trace("Setup global configuration as " ~ backend.globalConfiguration.base.toString);

		trace("Registering dub");
		backend.register!DubComponent(false);
		trace("Registering fsworkspace");
		backend.register!FSWorkspaceComponent(false);
		trace("Registering dcd");
		backend.register!DCDComponent(false);
		trace("Registering dcdext");
		backend.register!DCDExtComponent(false);
		trace("Registering dmd");
		backend.register!DMDComponent(false);
		trace("Starting dscanner");
		backend.register!DscannerComponent;
		trace("Starting dfmt");
		backend.register!DfmtComponent;
		trace("Starting dlangui");
		backend.register!DlanguiComponent;
		trace("Starting importer");
		backend.register!ImporterComponent;
		trace("Starting moduleman");
		backend.register!ModulemanComponent;

		if (backend.get!DCDComponent.isOutdated)
		{
			if (firstConfig.d.aggressiveUpdate)
				spawnFiber((&updateDCD).toDelegate);
			else
			{
				spawnFiber({
					auto action = translate!"d.ext.compileProgram"("DCD");
					auto res = rpc.window.requestMessage(MessageType.error, translate!"d.served.failDCD"(firstWorkspaceRootUri,
						firstConfig.d.dcdClientPath, firstConfig.d.dcdServerPath), [action]);
					if (res == action)
						spawnFiber((&updateDCD).toDelegate);
				});
			}
		}
	}
	catch (Exception e)
	{
		error("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
		error("Failed to fully globally initialize:");
		error(e);
		error("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
	}
}

struct RootSuggestion
{
	string dir;
	bool useDub;
}

RootSuggestion[] rootsForProject(string root, bool recursive, string[] blocked, string[] extra)
{
	RootSuggestion[] ret;
	bool rootDub = fs.exists(chainPath(root, "dub.json")) || fs.exists(chainPath(root, "dub.sdl"));
	if (!rootDub && fs.exists(chainPath(root, "package.json")))
	{
		auto packageJson = fs.readText(chainPath(root, "package.json"));
		try
		{
			auto json = parseJSON(packageJson);
			if (seemsLikeDubJson(json))
				rootDub = true;
		}
		catch (Exception)
		{
		}
	}
	ret ~= RootSuggestion(root, rootDub);
	if (recursive)
		foreach (pkg; fs.dirEntries(root, "dub.{json,sdl}", fs.SpanMode.depth))
		{
			auto dir = dirName(pkg);
			if (dir.canFind(".dub"))
				continue;
			if (dir == root)
				continue;
			if (blocked.any!(a => globMatch(dir.relativePath(root), a)
					|| globMatch(pkg.relativePath(root), a) || globMatch((dir ~ "/").relativePath, a)))
				continue;
			ret ~= RootSuggestion(dir, true);
		}
	foreach (dir; extra)
	{
		string p = buildNormalizedPath(root, dir);
		if (!ret.canFind!(a => a.dir == p))
			ret ~= RootSuggestion(p, fs.exists(chainPath(p, "dub.json"))
					|| fs.exists(chainPath(p, "dub.sdl")));
	}
	info("Root Suggestions: ", ret);
	return ret;
}

void doStartup(string workspaceUri)
{
	Workspace* proj = &workspace(workspaceUri);
	if (proj is &fallbackWorkspace)
	{
		error("Trying to do startup on unknown workspace ", workspaceUri, "?");
		return;
	}
	trace("Initializing serve-d for " ~ workspaceUri);

	foreach (root; rootsForProject(workspaceUri.uriToFile, proj.config.d.scanAllFolders,
			proj.config.d.disabledRootGlobs, proj.config.d.extraRoots))
	{
		auto workspaceRoot = root.dir;
		workspaced.api.Configuration config;
		config.base = JSONValue(["dcd" : JSONValue(["clientPath"
				: JSONValue(proj.config.d.dcdClientPath), "serverPath"
				: JSONValue(proj.config.d.dcdServerPath), "port" : JSONValue(9166)]),
				"dmd" : JSONValue(["path" : JSONValue(proj.config.d.dmdPath)])]);
		auto instance = backend.addInstance(workspaceRoot, config);

		bool disableDub = proj.config.d.neverUseDub || !root.useDub;
		bool loadedDub;
		if (!disableDub)
		{
			trace("Starting dub...");
			try
			{
				if (backend.attach(instance, "dub"))
					loadedDub = true;
			}
			catch (Exception e)
			{
				error("Exception starting dub: ", e);
			}
		}
		if (!loadedDub)
		{
			if (!disableDub)
			{
				error("Failed starting dub in ", root, " - falling back to fsworkspace");
				proj.startupError(workspaceRoot, translate!"d.ext.dubFail"(instance.cwd));
			}
			try
			{
				instance.config.set("fsworkspace", "additionalPaths",
						getPossibleSourceRoots(workspaceRoot));
				if (!backend.attach(instance, "fsworkspace"))
					throw new Exception("Attach returned failure");
			}
			catch (Exception e)
			{
				error(e);
				proj.startupError(workspaceRoot, translate!"d.ext.fsworkspaceFail"(instance.cwd));
			}
		}
		else
			setTimeout({ rpc.notifyMethod("coded/initDubTree"); }, 50);

		if (!backend.attach(instance, "dmd"))
			error("Failed to attach DMD component to ", workspaceUri);
		startDCD(instance, workspaceUri);

		trace("Loaded Components for ", instance.cwd, ": ",
				instance.instanceComponents.map!"a.info.name");
	}
}

void removeWorkspace(string workspaceUri)
{
	auto workspaceRoot = workspaceRootFor(workspaceUri);
	if (!workspaceRoot.length)
		return;
	backend.removeInstance(workspaceRoot);
	workspace(workspaceUri).disabled = true;
}

void handleBroadcast(WorkspaceD workspaced, WorkspaceD.Instance instance, JSONValue data)
{
	if (!instance)
		return;
	auto type = "type" in data;
	if (type && type.type == JSON_TYPE.STRING && type.str == "crash")
	{
		if (data["component"].str == "dcd")
			spawnFiber(() => startDCD(instance, instance.cwd.uriFromFile));
	}
}

void startDCD(WorkspaceD.Instance instance, string workspaceUri)
{
	if (shutdownRequested)
		return;
	Workspace* proj = &workspace(workspaceUri, false);
	if (proj is &fallbackWorkspace)
	{
		error("Trying to start DCD on unknown workspace ", workspaceUri, "?");
		return;
	}
	trace("Starting dcd");
	if (!backend.attach(instance, "dcd"))
		error("Failed to attach DCD component to ", instance.cwd);
	trace("Starting dcdext");
	if (!backend.attach(instance, "dcdext"))
		error("Failed to attach DCD component to ", instance.cwd);
	trace("Running DCD setup");
	try
	{
		trace("findAndSelectPort 9166");
		auto port = backend.get!DCDComponent(instance.cwd)
			.findAndSelectPort(cast(ushort) 9166).getYield;
		trace("Setting port to ", port);
		instance.config.set("dcd", "port", cast(int) port);
		trace("startServer ", proj.config.stdlibPath);
		backend.get!DCDComponent(instance.cwd).startServer(proj.config.stdlibPath);
		trace("refreshImports");
		backend.get!DCDComponent(instance.cwd).refreshImports();
	}
	catch (Exception e)
	{
		rpc.window.showErrorMessage(translate!"d.ext.dcdFail"(instance.cwd));
		error(e);
		trace("Instance Config: ", instance.config);
		return;
	}
	info("Imports for ", instance.cwd, ": ", backend.getInstance(instance.cwd).importPaths);

	auto globalDCD = backend.get!DCDComponent;
	if (!globalDCD.isActive)
	{
		globalDCD.fromRunning(globalDCD.getSupportsFullOutput, globalDCD.isUsingUnixDomainSockets
				? globalDCD.getSocketFile : "", globalDCD.isUsingUnixDomainSockets ? 0
				: globalDCD.getRunningPort);
	}
}

string determineOutputFolder()
{
	import std.process : environment;

	version (linux)
	{
		if (fs.exists(buildPath(environment["HOME"], ".local", "share")))
			return buildPath(environment["HOME"], ".local", "share", "code-d", "bin");
		else
			return buildPath(environment["HOME"], ".code-d", "bin");
	}
	else version (Windows)
	{
		return buildPath(environment["APPDATA"], "code-d", "bin");
	}
	else
	{
		return buildPath(environment["HOME"], ".code-d", "bin");
	}
}

@protocolNotification("served/updateDCD")
void updateDCD()
{
	rpc.notifyMethod("coded/logInstall", "Installing DCD");
	string outputFolder = determineOutputFolder;
	if (fs.exists(outputFolder))
		rmdirRecurseForce(outputFolder);
	if (!fs.exists(outputFolder))
		fs.mkdirRecurse(outputFolder);
	string[] platformOptions;
	version (Windows)
		platformOptions = ["--arch=x86_mscoff"];
	bool success = compileDependency(outputFolder, "DCD",
			"https://github.com/Hackerpilot/DCD.git", [[firstConfig.git.path,
			"submodule", "update", "--init", "--recursive"], ["dub", "build",
			"--config=client"] ~ platformOptions, ["dub", "build", "--config=server"] ~ platformOptions]);
	if (success)
	{
		string ext = "";
		version (Windows)
			ext = ".exe";
		string finalDestinationClient = buildPath(outputFolder, "DCD", "dcd-client" ~ ext);
		if (!fs.exists(finalDestinationClient))
			finalDestinationClient = buildPath(outputFolder, "DCD", "bin", "dcd-client" ~ ext);
		string finalDestinationServer = buildPath(outputFolder, "DCD", "dcd-server" ~ ext);
		if (!fs.exists(finalDestinationServer))
			finalDestinationServer = buildPath(outputFolder, "DCD", "bin", "dcd-server" ~ ext);
		foreach (ref workspace; workspaces)
		{
			workspace.config.d.dcdClientPath = finalDestinationClient;
			workspace.config.d.dcdServerPath = finalDestinationServer;
		}
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdClientPath",
				JSONValue(finalDestinationClient), true));
		rpc.notifyMethod("coded/updateSetting", UpdateSettingParams("dcdServerPath",
				JSONValue(finalDestinationServer), true));
		rpc.notifyMethod("coded/logInstall", "Successfully installed DCD");
		foreach (ref workspace; workspaces)
		{
			auto instance = backend.getInstance(workspace.folder.uri.uriToFile);
			if (instance is null)
				rpc.notifyMethod("coded/logInstall",
						"Failed to find workspace to start DCD for " ~ workspace.folder.uri);
			else
				startDCD(instance, workspace.folder.uri);
		}
	}
}

bool compileDependency(string cwd, string name, string gitURI, string[][] commands)
{
	import std.process;

	int run(string[] cmd, string cwd)
	{
		import core.thread;

		rpc.notifyMethod("coded/logInstall", "> " ~ cmd.join(" "));
		auto stdin = pipe();
		auto stdout = pipe();
		auto pid = spawnProcess(cmd, stdin.readEnd, stdout.writeEnd,
				stdout.writeEnd, null, Config.none, cwd);
		stdin.writeEnd.close();
		size_t i;
		string[] lines;
		bool done;
		new Thread({
			scope (exit)
				done = true;
			foreach (line; stdout.readEnd.byLine)
				lines ~= line.idup;
		}).start();
		while (!pid.tryWait().terminated || !done || i < lines.length)
		{
			if (i < lines.length)
			{
				rpc.notifyMethod("coded/logInstall", lines[i++]);
			}
			Fiber.yield();
		}
		return pid.wait;
	}

	rpc.notifyMethod("coded/logInstall", "Installing into " ~ cwd);
	try
	{
		auto newCwd = buildPath(cwd, name);
		if (fs.exists(newCwd))
		{
			rpc.notifyMethod("coded/logInstall", "Deleting old installation from " ~ newCwd);
			try
			{
				rmdirRecurseForce(newCwd);
			}
			catch (Exception)
			{
				rpc.notifyMethod("coded/logInstall", "WARNING: Failed to delete " ~ newCwd);
			}
		}
		auto ret = run([firstConfig.git.path, "clone", "--recursive", "--depth=1", gitURI, name], cwd);
		if (ret != 0)
			throw new Exception("git ended with error code " ~ ret.to!string);
		foreach (command; commands)
			run(command, newCwd);
		return true;
	}
	catch (Exception e)
	{
		rpc.notifyMethod("coded/logInstall", "Failed to install " ~ name);
		rpc.notifyMethod("coded/logInstall", e.toString);
		return false;
	}
}

@protocolMethod("shutdown")
JSONValue shutdown()
{
	shutdownRequested = true;
	backend.shutdown();
	backend.destroy();
	served.extension.setTimeout({
		throw new Error("RPC still running 1s after shutdown");
	}, 1.seconds);
	return JSONValue(null);
}

CompletionItemKind convertFromDCDType(string type)
{
	switch (type)
	{
	case "c":
		return CompletionItemKind.class_;
	case "i":
		return CompletionItemKind.interface_;
	case "s":
	case "u":
		return CompletionItemKind.unit;
	case "a":
	case "A":
	case "v":
		return CompletionItemKind.variable;
	case "m":
	case "e":
		return CompletionItemKind.field;
	case "k":
		return CompletionItemKind.keyword;
	case "f":
		return CompletionItemKind.function_;
	case "g":
		return CompletionItemKind.enum_;
	case "P":
	case "M":
		return CompletionItemKind.module_;
	case "l":
		return CompletionItemKind.reference;
	case "t":
	case "T":
		return CompletionItemKind.property;
	default:
		return CompletionItemKind.text;
	}
}

SymbolKind convertFromDCDSearchType(string type)
{
	switch (type)
	{
	case "c":
		return SymbolKind.class_;
	case "i":
		return SymbolKind.interface_;
	case "s":
	case "u":
		return SymbolKind.package_;
	case "a":
	case "A":
	case "v":
		return SymbolKind.variable;
	case "m":
	case "e":
		return SymbolKind.field;
	case "f":
	case "l":
		return SymbolKind.function_;
	case "g":
		return SymbolKind.enum_;
	case "P":
	case "M":
		return SymbolKind.namespace;
	case "t":
	case "T":
		return SymbolKind.property;
	case "k":
	default:
		return cast(SymbolKind) 0;
	}
}

SymbolKind convertFromDscannerType(string type)
{
	switch (type)
	{
	case "g":
		return SymbolKind.enum_;
	case "e":
		return SymbolKind.field;
	case "v":
		return SymbolKind.variable;
	case "i":
		return SymbolKind.interface_;
	case "c":
		return SymbolKind.class_;
	case "s":
		return SymbolKind.class_;
	case "f":
		return SymbolKind.function_;
	case "u":
		return SymbolKind.class_;
	case "T":
		return SymbolKind.property;
	case "a":
		return SymbolKind.field;
	default:
		return cast(SymbolKind) 0;
	}
}

string substr(T)(string s, T start, T end)
{
	if (!s.length)
		return "";
	if (start < 0)
		start = 0;
	if (start >= s.length)
		start = s.length - 1;
	if (end > s.length)
		end = s.length;
	if (end < start)
		return s[start .. start];
	return s[start .. end];
}

string[] extractFunctionParameters(string sig, bool exact = false)
{
	if (!sig.length)
		return [];
	string[] params;
	ptrdiff_t i = sig.length - 1;

	if (sig[i] == ')' && !exact)
		i--;

	ptrdiff_t paramEnd = i + 1;

	void skipStr()
	{
		i--;
		if (sig[i + 1] == '\'')
			for (; i >= 0; i--)
				if (sig[i] == '\'')
					return;
		bool escapeNext = false;
		while (i >= 0)
		{
			if (sig[i] == '\\')
				escapeNext = false;
			if (escapeNext)
				break;
			if (sig[i] == '"')
				escapeNext = true;
			i--;
		}
	}

	void skip(char open, char close)
	{
		i--;
		int depth = 1;
		while (i >= 0 && depth > 0)
		{
			if (sig[i] == '"' || sig[i] == '\'')
				skipStr();
			else
			{
				if (sig[i] == close)
					depth++;
				else if (sig[i] == open)
					depth--;
				i--;
			}
		}
	}

	while (i >= 0)
	{
		switch (sig[i])
		{
		case ',':
			params ~= sig.substr(i + 1, paramEnd).strip;
			paramEnd = i;
			i--;
			break;
		case ';':
		case '(':
			auto param = sig.substr(i + 1, paramEnd).strip;
			if (param.length)
				params ~= param;
			reverse(params);
			return params;
		case ')':
			skip('(', ')');
			break;
		case '}':
			skip('{', '}');
			break;
		case ']':
			skip('[', ']');
			break;
		case '"':
		case '\'':
			skipStr();
			break;
		default:
			i--;
			break;
		}
	}
	reverse(params);
	return params;
}

unittest
{
	void assertEqual(A, B)(A a, B b)
	{
		import std.conv : to;

		assert(a == b, a.to!string ~ " is not equal to " ~ b.to!string);
	}

	assertEqual(extractFunctionParameters("void foo()"), cast(string[])[]);
	assertEqual(extractFunctionParameters(`auto bar(int foo, Button, my.Callback cb)`),
			["int foo", "Button", "my.Callback cb"]);
	assertEqual(extractFunctionParameters(`SomeType!(int, "int_") foo(T, Args...)(T a, T b, string[string] map, Other!"(" stuff1, SomeType!(double, ")double") myType, Other!"(" stuff, Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double, ")double") myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEqual(extractFunctionParameters(`SomeType!(int,"int_")foo(T,Args...)(T a,T b,string[string] map,Other!"(" stuff1,SomeType!(double,")double")myType,Other!"(" stuff,Other!")")`),
			["T a", "T b", "string[string] map", `Other!"(" stuff1`,
			`SomeType!(double,")double")myType`, `Other!"(" stuff`, `Other!")"`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4`,
			true), [`4`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, f(4)`,
			true), [`4`, `f(4)`]);
	assertEqual(extractFunctionParameters(`some_garbage(code); before(this); funcCall(4, ["a"], JSONValue(["b": JSONValue("c")]), recursive(func, call!s()), "texts )\"(too"`,
			true), [`4`, `["a"]`, `JSONValue(["b": JSONValue("c")])`,
			`recursive(func, call!s())`, `"texts )\"(too"`]);
}

// === Protocol Methods starting here ===

@protocolMethod("textDocument/completion")
CompletionList provideComplete(TextDocumentPositionParams params)
{
	import painlessjson : fromJSON;

	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	Document document = documents[params.textDocument.uri];
	if (document.uri.toLower.endsWith("dscanner.ini"))
	{
		auto possibleFields = backend.get!DscannerComponent.listAllIniFields;
		auto line = document.lineAt(params.position).strip;
		auto defaultList = CompletionList(false, possibleFields.map!(a => CompletionItem(a.name,
				CompletionItemKind.field.opt, Optional!string.init, MarkupContent(a.documentation)
				.opt, Optional!string.init, Optional!string.init, (a.name ~ '=').opt)).array);
		if (!line.length)
			return defaultList;
		//dfmt off
		if (line[0] == '[')
			return CompletionList(false, [
				CompletionItem("analysis.config.StaticAnalysisConfig", CompletionItemKind.keyword.opt),
				CompletionItem("analysis.config.ModuleFilters", CompletionItemKind.keyword.opt, Optional!string.init,
					MarkupContent("In this optional section a comma-separated list of inclusion and exclusion"
					~ " selectors can be specified for every check on which selective filtering"
					~ " should be applied. These given selectors match on the module name and"
					~ " partial matches (std. or .foo.) are possible. Moreover, every selectors"
					~ " must begin with either + (inclusion) or - (exclusion). Exclusion selectors"
					~ " take precedence over all inclusion operators.").opt)
			]);
		//dfmt on
		auto eqIndex = line.indexOf('=');
		auto quotIndex = line.lastIndexOf('"');
		if (quotIndex != -1 && params.position.character >= quotIndex)
			return CompletionList.init;
		if (params.position.character < eqIndex)
			return defaultList;
		else//dfmt off
			return CompletionList(false, [
				CompletionItem(`"disabled"`, CompletionItemKind.value.opt, "Check is disabled".opt),
				CompletionItem(`"enabled"`, CompletionItemKind.value.opt, "Check is enabled".opt),
				CompletionItem(`"skip-unittest"`, CompletionItemKind.value.opt,
					"Check is enabled but not operated in the unittests".opt)
			]);
		//dfmt on
	}
	else
	{
		if (document.languageId != "d")
			return CompletionList.init;
		string line = document.lineAt(params.position);
		string prefix = line[0 .. min($, params.position.character)];
		CompletionItem[] completion;
		if (prefix.strip == "///" || prefix.strip == "*")
		{
			foreach (compl; import("ddocs.txt").lineSplitter)
			{
				auto item = CompletionItem(compl, CompletionItemKind.snippet.opt);
				item.insertText = compl ~ ": ";
				completion ~= item;
			}
			return CompletionList(false, completion);
		}
		auto byteOff = cast(int) document.positionToBytes(params.position);
		DCDCompletions result = DCDCompletions.empty;
		joinAll({
			if (backend.has!DCDComponent(workspaceRoot))
				result = backend.get!DCDComponent(workspaceRoot)
					.listCompletion(document.text, byteOff).getYield;
		}, {
			if (!line.strip.length)
			{
				auto defs = backend.get!DscannerComponent(workspaceRoot)
					.listDefinitions(uriToFile(params.textDocument.uri), document.text).getYield;
				ptrdiff_t di = -1;
				FuncFinder: foreach (i, def; defs)
				{
					for (int n = 1; n < 5; n++)
						if (def.line == params.position.line + n)
						{
							di = i;
							break FuncFinder;
						}
				}
				if (di == -1)
					return;
				auto def = defs[di];
				auto sig = "signature" in def.attributes;
				if (!sig)
				{
					CompletionItem doc = CompletionItem("///");
					doc.kind = CompletionItemKind.snippet;
					doc.insertTextFormat = InsertTextFormat.snippet;
					auto eol = document.eolAt(params.position.line).toString;
					doc.insertText = "/// ";
					CompletionItem doc2 = doc;
					doc2.label = "/**";
					doc2.insertText = "/** " ~ eol ~ " * $0" ~ eol ~ " */";
					completion ~= doc;
					completion ~= doc2;
					return;
				}
				auto funcArgs = extractFunctionParameters(*sig);
				string[] docs;
				if (def.name.matchFirst(ctRegex!`^[Gg]et([^a-z]|$)`))
					docs ~= "Gets $0";
				else if (def.name.matchFirst(ctRegex!`^[Ss]et([^a-z]|$)`))
					docs ~= "Sets $0";
				else if (def.name.matchFirst(ctRegex!`^[Ii]s([^a-z]|$)`))
					docs ~= "Checks if $0";
				else
					docs ~= "$0";
				int argNo = 1;
				foreach (arg; funcArgs)
				{
					auto space = arg.lastIndexOf(' ');
					if (space == -1)
						continue;
					string identifier = arg[space + 1 .. $];
					if (!identifier.matchFirst(ctRegex!`[a-zA-Z_][a-zA-Z0-9_]*`))
						continue;
					if (argNo == 1)
						docs ~= "Params:";
					docs ~= "  " ~ identifier ~ " = $" ~ argNo.to!string;
					argNo++;
				}
				auto retAttr = "return" in def.attributes;
				if (retAttr && *retAttr != "void")
				{
					docs ~= "Returns: $" ~ argNo.to!string;
					argNo++;
				}
				auto depr = "deprecation" in def.attributes;
				if (depr)
				{
					docs ~= "Deprecated: $" ~ argNo.to!string ~ *depr;
					argNo++;
				}
				CompletionItem doc = CompletionItem("///");
				doc.kind = CompletionItemKind.snippet;
				doc.insertTextFormat = InsertTextFormat.snippet;
				auto eol = document.eolAt(params.position.line).toString;
				doc.insertText = docs.map!(a => "/// " ~ a).join(eol);
				CompletionItem doc2 = doc;
				doc2.label = "/**";
				doc2.insertText = "/** " ~ eol ~ docs.map!(a => " * " ~ a ~ eol).join() ~ " */";
				completion ~= doc;
				completion ~= doc2;
			}
		});
		switch (result.type)
		{
		case DCDCompletions.Type.identifiers:
			foreach (identifier; result.identifiers)
			{
				CompletionItem item;
				item.label = identifier.identifier;
				item.kind = identifier.type.convertFromDCDType;
				if (identifier.documentation.length)
					item.documentation = MarkupContent(identifier.documentation.ddocToMarked);
				if (identifier.definition.length)
				{
					item.detail = identifier.definition;
					item.sortText = identifier.definition;
					// TODO: only add arguments when this is a function call, eg not on template arguments
					if (identifier.type == "f" && workspace(params.textDocument.uri)
							.config.d.argumentSnippets)
					{
						item.insertTextFormat = InsertTextFormat.snippet;
						string args;
						auto parts = identifier.definition.extractFunctionParameters;
						if (parts.length)
						{
							bool isOptional;
							string[] optionals;
							int numRequired;
							foreach (i, part; parts)
							{
								if (!isOptional)
									isOptional = part.canFind('=');
								if (isOptional)
									optionals ~= part;
								else
								{
									if (args.length)
										args ~= ", ";
									args ~= "${" ~ (i + 1).to!string ~ ":" ~ part ~ "}";
									numRequired++;
								}
							}
							foreach (i, part; optionals)
							{
								if (args.length)
									part = ", " ~ part;
								// Go through optionals in reverse
								args ~= "${" ~ (numRequired + optionals.length - i).to!string ~ ":" ~ part ~ "}";
							}
							item.insertText = identifier.identifier ~ "(${0:" ~ args ~ "})";
						}
					}
				}
				completion ~= item;
			}
			goto case;
		case DCDCompletions.Type.calltips:
			return CompletionList(false, completion);
		default:
			throw new Exception("Unexpected result from DCD:\n\t" ~ result.raw.join("\n\t"));
		}
	}
}

@protocolMethod("textDocument/signatureHelp")
SignatureHelp provideSignatureHelp(TextDocumentPositionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return SignatureHelp.init;
	auto pos = cast(int) document.positionToBytes(params.position);
	DCDCompletions result = backend.get!DCDComponent(workspaceRoot)
		.listCompletion(document.text, pos).getYield;
	SignatureInformation[] signatures;
	int[] paramsCounts;
	SignatureHelp help;
	switch (result.type)
	{
	case DCDCompletions.Type.calltips:
		foreach (i, calltip; result.calltips)
		{
			auto sig = SignatureInformation(calltip);
			immutable DCDCompletions.Symbol symbol = result.symbols[i];
			if (symbol.documentation.length)
				sig.documentation = MarkupContent(symbol.documentation.ddocToMarked);
			auto funcParams = calltip.extractFunctionParameters;

			paramsCounts ~= cast(int) funcParams.length - 1;
			foreach (param; funcParams)
				sig.parameters ~= ParameterInformation(param);

			help.signatures ~= sig;
		}
		auto extractedParams = document.text[0 .. pos].extractFunctionParameters(true);
		help.activeParameter = max(0, cast(int) extractedParams.length - 1);
		size_t[] possibleFunctions;
		foreach (i, count; paramsCounts)
			if (count >= cast(int) extractedParams.length - 1)
				possibleFunctions ~= i;
		help.activeSignature = possibleFunctions.length ? cast(int) possibleFunctions[0] : 0;
		goto case;
	case DCDCompletions.Type.identifiers:
		return help;
	default:
		throw new Exception("Unexpected result from DCD");
	}
}

@protocolMethod("workspace/symbol")
SymbolInformation[] provideWorkspaceSymbols(WorkspaceSymbolParams params)
{
	import std.file;

	// TODO: combine all workspaces
	auto result = backend.get!DCDComponent(workspaceRoot).searchSymbol(params.query).getYield;
	SymbolInformation[] infos;
	TextDocumentManager extraCache;
	foreach (symbol; result.array)
	{
		auto uri = uriFromFile(symbol.file);
		auto doc = documents.tryGet(uri);
		Location location;
		if (!doc.uri)
			doc = extraCache.tryGet(uri);
		if (!doc.uri)
		{
			doc = Document(uri);
			try
			{
				doc.text = readText(symbol.file);
			}
			catch (Exception e)
			{
				error(e);
			}
		}
		if (doc.text)
		{
			location = Location(doc.uri, TextRange(doc.bytesToPosition(cast(size_t) symbol.position)));
			infos ~= SymbolInformation(params.query, convertFromDCDSearchType(symbol.type), location);
		}
	}
	return infos;
}

@protocolMethod("textDocument/documentSymbol")
SymbolInformation[] provideDocumentSymbols(DocumentSymbolParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	auto result = backend.get!DscannerComponent(workspaceRoot)
		.listDefinitions(uriToFile(params.textDocument.uri), document.text).getYield;
	SymbolInformation[] ret;
	foreach (def; result)
	{
		SymbolInformation info;
		info.name = def.name;
		info.location.uri = params.textDocument.uri;
		info.location.range = TextRange(Position(cast(uint) def.line - 1, 0));
		info.kind = convertFromDscannerType(def.type);
		if (def.type == "f" && def.name == "this")
			info.kind = SymbolKind.constructor;
		string* ptr;
		auto attribs = def.attributes;
		if ((ptr = "struct" in attribs) !is null || (ptr = "class" in attribs) !is null
				|| (ptr = "enum" in attribs) !is null || (ptr = "union" in attribs) !is null)
			info.containerName = *ptr;
		ret ~= info;
	}
	return ret;
}

@protocolMethod("textDocument/definition")
ArrayOrSingle!Location provideDefinition(TextDocumentPositionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return ArrayOrSingle!Location.init;
	auto result = backend.get!DCDComponent(workspaceRoot).findDeclaration(document.text,
			cast(int) document.positionToBytes(params.position)).getYield;
	if (result == DCDDeclaration.init)
		return ArrayOrSingle!Location.init;
	auto uri = document.uri;
	if (result.file != "stdin")
	{
		if (isAbsolute(result.file))
			uri = uriFromFile(result.file);
		else
			uri = null;
	}
	size_t byteOffset = cast(size_t) result.position;
	Position pos;
	auto found = documents.tryGet(uri);
	if (found.uri)
		pos = found.bytesToPosition(byteOffset);
	else
	{
		string abs = result.file;
		if (!abs.isAbsolute)
			abs = buildPath(workspaceRoot, abs);
		pos = Position.init;
		size_t totalLen;
		foreach (line; io.File(abs).byLine(io.KeepTerminator.yes))
		{
			totalLen += line.length;
			if (totalLen >= byteOffset)
				break;
			else
				pos.line++;
		}
	}
	return ArrayOrSingle!Location(Location(uri, TextRange(pos, pos)));
}

@protocolMethod("textDocument/formatting")
TextEdit[] provideFormatting(DocumentFormattingParams params)
{
	auto config = workspace(params.textDocument.uri).config;
	if (!config.d.enableFormatting)
		return [];
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	string[] args;
	if (config.d.overrideDfmtEditorconfig)
	{
		int maxLineLength = 120;
		int softMaxLineLength = 80;
		if (config.editor.rulers.length == 1)
		{
			maxLineLength = config.editor.rulers[0];
			softMaxLineLength = maxLineLength - 40;
		}
		else if (config.editor.rulers.length >= 2)
		{
			maxLineLength = config.editor.rulers[$ - 1];
			softMaxLineLength = config.editor.rulers[$ - 2];
		}
		//dfmt off
			args = [
				"--align_switch_statements", config.dfmt.alignSwitchStatements.to!string,
				"--brace_style", config.dfmt.braceStyle,
				"--end_of_line", document.eolAt(0).to!string,
				"--indent_size", params.options.tabSize.to!string,
				"--indent_style", params.options.insertSpaces ? "space" : "tab",
				"--max_line_length", maxLineLength.to!string,
				"--soft_max_line_length", softMaxLineLength.to!string,
				"--outdent_attributes", config.dfmt.outdentAttributes.to!string,
				"--space_after_cast", config.dfmt.spaceAfterCast.to!string,
				"--split_operator_at_line_end", config.dfmt.splitOperatorAtLineEnd.to!string,
				"--tab_width", params.options.tabSize.to!string,
				"--selective_import_space", config.dfmt.selectiveImportSpace.to!string,
				"--compact_labeled_statements", config.dfmt.compactLabeledStatements.to!string,
				"--template_constraint_style", config.dfmt.templateConstraintStyle
			];
			//dfmt on
	}
	auto result = backend.get!DfmtComponent.format(document.text, args).getYield;
	return [TextEdit(TextRange(Position(0, 0),
			document.offsetToPosition(document.text.length)), result)];
}

@protocolMethod("textDocument/hover")
Hover provideHover(TextDocumentPositionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return Hover.init;
	auto docs = backend.get!DCDComponent(workspaceRoot).getDocumentation(document.text,
			cast(int) document.positionToBytes(params.position)).getYield;
	Hover ret;
	ret.contents = docs.ddocToMarked;
	return ret;
}

private auto importRegex = regex(`import\s+(?:[a-zA-Z_]+\s*=\s*)?([a-zA-Z_]\w*(?:\.\w*[a-zA-Z_]\w*)*)?(\s*\:\s*(?:[a-zA-Z_,\s=]*(?://.*?[\r\n]|/\*.*?\*/|/\+.*?\+/)?)+)?;?`);
private auto undefinedIdentifier = regex(
		`^undefined identifier '(\w+)'(?:, did you mean .*? '(\w+)'\?)?$`);
private auto undefinedTemplate = regex(`template '(\w+)' is not defined`);
private auto noProperty = regex(`^no property '(\w+)'(?: for type '.*?')?$`);
private auto moduleRegex = regex(`module\s+([a-zA-Z_]\w*\s*(?:\s*\.\s*[a-zA-Z_]\w*)*)\s*;`);
private auto whitespace = regex(`\s*`);

@protocolMethod("textDocument/codeAction")
Command[] provideCodeActions(CodeActionParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	Command[] ret;
	if (backend.has!DCDExtComponent(workspaceRoot)) // check if extends
	{
		auto startIndex = document.positionToBytes(params.range.start);
		ptrdiff_t idx = min(cast(ptrdiff_t) startIndex, cast(ptrdiff_t) document.text.length - 1);
		while (idx > 0)
		{
			if (document.text[idx] == ':')
			{
				// probably extends
				if (backend.get!DCDExtComponent(workspaceRoot)
						.implement(document.text, cast(int) startIndex).getYield.strip.length > 0)
					ret ~= Command("Implement base classes/interfaces", "code-d.implementMethods",
							[JSONValue(document.positionToOffset(params.range.start))]);
				break;
			}
			if (document.text[idx] == ';' || document.text[idx] == '{' || document.text[idx] == '}')
				break;
			idx--;
		}
	}
	foreach (diagnostic; params.context.diagnostics)
	{
		if (diagnostic.source == DubDiagnosticSource)
		{
			auto match = diagnostic.message.matchFirst(importRegex);
			if (diagnostic.message.canFind("import "))
			{
				if (!match)
					continue;
				ret ~= Command("Import " ~ match[1], "code-d.addImport",
						[JSONValue(match[1]), JSONValue(document.positionToOffset(params.range[0]))]);
			}
			else /*if (cast(bool)(match = diagnostic.message.matchFirst(undefinedIdentifier))
					|| cast(bool)(match = diagnostic.message.matchFirst(undefinedTemplate))
					|| cast(bool)(match = diagnostic.message.matchFirst(noProperty)))*/
			{
				// temporary fix for https://issues.dlang.org/show_bug.cgi?id=18565
				string[] files;
				string[] modules;
				int lineNo;
				match = diagnostic.message.matchFirst(undefinedIdentifier);
				if (match)
					goto start;
				match = diagnostic.message.matchFirst(undefinedTemplate);
				if (match)
					goto start;
				match = diagnostic.message.matchFirst(noProperty);
				if (match)
					goto start;
				goto noMatch;
			start:
				joinAll({
					files ~= backend.get!DscannerComponent(workspaceRoot)
						.findSymbol(match[1]).getYield.map!"a.file".array;
				}, {
					if (backend.has!DCDComponent)
						files ~= backend.get!DCDComponent.searchSymbol(match[1]).getYield.map!"a.file".array;
				});
				foreach (file; files.sort().uniq)
				{
					if (!isAbsolute(file))
						file = buildNormalizedPath(workspaceRoot, file);
					lineNo = 0;
					foreach (line; io.File(file).byLine)
					{
						if (++lineNo >= 100)
							break;
						auto match2 = line.matchFirst(moduleRegex);
						if (match2)
						{
							modules ~= match2[1].replaceAll(whitespace, "").idup;
							break;
						}
					}
				}
				foreach (mod; modules.sort().uniq)
					ret ~= Command("Import " ~ mod, "code-d.addImport", [JSONValue(mod),
							JSONValue(document.positionToOffset(params.range[0]))]);
			noMatch:
			}
		}
		else
		{
			import dscanner.analysis.imports_sortedness : ImportSortednessCheck;

			if (diagnostic.message == ImportSortednessCheck.MESSAGE)
			{
				ret ~= Command("Sort imports", "code-d.sortImports",
						[JSONValue(document.positionToOffset(params.range[0]))]);
			}
		}
	}
	return ret;
}

@protocolMethod("textDocument/codeLens")
CodeLens[] provideCodeLens(CodeLensParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return [];
	CodeLens[] ret;
	if (workspace(params.textDocument.uri).config.d.enableDMDImportTiming)
		foreach (match; document.text.matchAll(importRegex))
		{
			size_t index = match.pre.length;
			auto pos = document.bytesToPosition(index);
			ret ~= CodeLens(TextRange(pos), Optional!Command.init, JSONValue(["type"
					: JSONValue("importcompilecheck"), "code" : JSONValue(match.hit),
					"module" : JSONValue(match[1]), "workspace" : JSONValue(workspaceRoot)]));
		}
	return ret;
}

@protocolMethod("codeLens/resolve")
CodeLens resolveCodeLens(CodeLens lens)
{
	if (lens.data.type != JSON_TYPE.OBJECT)
		throw new Exception("Invalid Lens Object");
	auto type = "type" in lens.data;
	if (!type)
		throw new Exception("No type in Lens Object");
	switch (type.str)
	{
	case "importcompilecheck":
		auto code = "code" in lens.data;
		if (!code || code.type != JSON_TYPE.STRING || !code.str.length)
			throw new Exception("No valid code provided");
		auto module_ = "module" in lens.data;
		if (!module_ || module_.type != JSON_TYPE.STRING || !module_.str.length)
			throw new Exception("No valid module provided");
		auto workspace = "workspace" in lens.data;
		if (!workspace || workspace.type != JSON_TYPE.STRING || !workspace.str.length)
			throw new Exception("No valid workspace provided");
		int decMs = getImportCompilationTime(code.str, module_.str, workspace.str);
		lens.command = Command((decMs < 10 ? "no noticable effect"
				: "~" ~ decMs.to!string ~ "ms") ~ " for importing this");
		return lens;
	default:
		throw new Exception("Unknown lens type");
	}
}

bool importCompilationTimeRunning;
int getImportCompilationTime(string code, string module_, string workspaceRoot)
{
	import std.math : round;

	static struct CompileCache
	{
		SysTime at;
		string code;
		int ret;
	}

	static CompileCache[] cache;

	auto now = Clock.currTime;

	foreach_reverse (i, exist; cache)
	{
		if (exist.code != code)
			continue;
		if (now - exist.at < (exist.ret >= 500 ? 20.minutes : exist.ret >= 30 ? 5.minutes
				: 2.minutes) || module_.startsWith("std."))
			return exist.ret;
		else
		{
			cache[i] = cache[$ - 1];
			cache.length--;
		}
	}

	while (importCompilationTimeRunning)
		Fiber.yield();
	importCompilationTimeRunning = true;
	scope (exit)
		importCompilationTimeRunning = false;
	// run blocking so we don't compute multiple in parallel
	auto ret = backend.get!DMDComponent(workspaceRoot).measureSync(code, null, 20, 500);
	if (!ret.success)
		throw new Exception("Compilation failed");
	auto msecs = cast(int) round(ret.duration.total!"msecs" / 5.0) * 5;
	cache ~= CompileCache(now, code, msecs);
	StopWatch sw;
	sw.start();
	while (sw.peek < 100.msecs) // pass through requests for 100ms
		Fiber.yield();
	return msecs;
}

@protocolMethod("served/listConfigurations")
string[] listConfigurations()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).configurations;
}

@protocolMethod("served/switchConfig")
bool switchConfig(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).setConfiguration(value);
}

@protocolMethod("served/getConfig")
string getConfig(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).configuration;
}

@protocolMethod("served/listArchTypes")
string[] listArchTypes()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).archTypes;
}

@protocolMethod("served/switchArchType")
bool switchArchType(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot)
		.setArchType(JSONValue(["arch-type" : JSONValue(value)]));
}

@protocolMethod("served/getArchType")
string getArchType(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).archType;
}

@protocolMethod("served/listBuildTypes")
string[] listBuildTypes()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).buildTypes;
}

@protocolMethod("served/switchBuildType")
bool switchBuildType(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot)
		.setBuildType(JSONValue(["build-type" : JSONValue(value)]));
}

@protocolMethod("served/getBuildType")
string getBuildType()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).buildType;
}

@protocolMethod("served/getCompiler")
string getCompiler()
{
	return backend.get!DubComponent(selectedWorkspaceRoot).compiler;
}

@protocolMethod("served/switchCompiler")
bool switchCompiler(string value)
{
	return backend.get!DubComponent(selectedWorkspaceRoot).setCompiler(value);
}

@protocolMethod("served/addImport")
auto addImport(AddImportParams params)
{
	auto document = documents[params.textDocument.uri];
	return backend.get!ImporterComponent.add(params.name.idup, document.text,
			params.location, params.insertOutermost);
}

@protocolMethod("served/sortImports")
TextEdit[] sortImports(SortImportsParams params)
{
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto sorted = backend.get!ImporterComponent.sortImports(document.text,
			cast(int) document.offsetToBytes(params.location));
	if (sorted == ImportBlock.init)
		return ret;
	auto start = document.bytesToPosition(sorted.start);
	auto end = document.bytesToPosition(sorted.end);
	string code = sorted.imports.to!(string[]).join(document.eolAt(0).toString);
	return [TextEdit(TextRange(start, end), code)];
}

@protocolMethod("served/implementMethods")
TextEdit[] implementMethods(ImplementMethodsParams params)
{
	import std.ascii : isWhite;

	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto document = documents[params.textDocument.uri];
	TextEdit[] ret;
	auto location = document.offsetToBytes(params.location);
	auto code = backend.get!DCDExtComponent(workspaceRoot)
		.implement(document.text, cast(int) location).getYield.strip;
	if (!code.length)
		return ret;
	auto brace = document.text.indexOf('{', location);
	auto fallback = brace;
	if (brace == -1)
		brace = document.text.length;
	else
	{
		fallback = document.text.indexOf('\n', location);
		brace = document.text.indexOfAny("}\n", brace);
		if (brace == -1)
			brace = document.text.length;
	}
	code = "\n\t" ~ code.replace("\n", document.eolAt(0).toString ~ "\t") ~ "\n";
	bool inIdentifier = true;
	int depth = 0;
	foreach (i; location .. brace)
	{
		if (document.text[i].isWhite)
			inIdentifier = false;
		else if (document.text[i] == '{')
			break;
		else if (document.text[i] == ',' || document.text[i] == '!')
			inIdentifier = true;
		else if (document.text[i] == '(')
			depth++;
		else
		{
			if (depth > 0)
			{
				inIdentifier = true;
				if (document.text[i] == ')')
					depth--;
			}
			else if (!inIdentifier)
			{
				if (fallback != -1)
					brace = fallback;
				code = "\n{" ~ code ~ "}";
				break;
			}
		}
	}
	auto pos = document.bytesToPosition(brace);
	return [TextEdit(TextRange(pos, pos), code)];
}

@protocolMethod("served/restartServer")
bool restartServer()
{
	backend.get!DCDComponent.restartServer().getYield;
	return true;
}

@protocolMethod("served/updateImports")
bool updateImports()
{
	auto workspaceRoot = selectedWorkspaceRoot;
	bool success;
	if (backend.has!DubComponent(workspaceRoot))
	{
		success = backend.get!DubComponent(workspaceRoot).update.getYield;
		if (success)
			rpc.notifyMethod("coded/updateDubTree");
	}
	backend.get!DCDComponent(workspaceRoot).refreshImports();
	return success;
}

@protocolMethod("served/listDependencies")
DubDependency[] listDependencies(string packageName)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	DubDependency[] ret;
	auto allDeps = backend.get!DubComponent(workspaceRoot).dependencies;
	if (!packageName.length)
	{
		auto deps = backend.get!DubComponent(workspaceRoot).rootDependencies;
		foreach (dep; deps)
		{
			DubDependency r;
			r.name = dep;
			r.root = true;
			foreach (other; allDeps)
				if (other.name == dep)
				{
					r.version_ = other.ver;
					r.path = other.path;
					r.description = other.description;
					r.homepage = other.homepage;
					r.authors = other.authors;
					r.copyright = other.copyright;
					r.license = other.license;
					r.subPackages = other.subPackages.map!"a.name".array;
					r.hasDependencies = other.dependencies.length > 0;
					break;
				}
			ret ~= r;
		}
	}
	else
	{
		string[string] aa;
		foreach (other; allDeps)
			if (other.name == packageName)
			{
				aa = other.dependencies;
				break;
			}
		foreach (name, ver; aa)
		{
			DubDependency r;
			r.name = name;
			r.version_ = ver;
			foreach (other; allDeps)
				if (other.name == name)
				{
					r.path = other.path;
					r.description = other.description;
					r.homepage = other.homepage;
					r.authors = other.authors;
					r.copyright = other.copyright;
					r.license = other.license;
					r.subPackages = other.subPackages.map!"a.name".array;
					r.hasDependencies = other.dependencies.length > 0;
					break;
				}
			ret ~= r;
		}
	}
	return ret;
}

// === Protocol Notifications starting here ===

struct FileOpenInfo
{
	SysTime at;
}

__gshared FileOpenInfo[string] freshlyOpened;

@protocolNotification("workspace/didChangeWatchedFiles")
void onChangeFiles(DidChangeWatchedFilesParams params)
{
	foreach (change; params.changes)
	{
		string file = change.uri;
		if (change.type == FileChangeType.created && file.endsWith(".d"))
		{
			auto document = documents[file];
			auto isNew = file in freshlyOpened;
			info(file);
			if (isNew)
			{
				// Only edit if creation & opening is < 800msecs apart (vscode automatically opens on creation),
				// we don't want to affect creation from/in other programs/editors.
				if (Clock.currTime - isNew.at > 800.msecs)
				{
					freshlyOpened.remove(file);
					continue;
				}
				// Sending applyEdit so it is undoable
				auto patches = backend.get!ModulemanComponent.normalizeModules(file.uriToFile,
						document.text);
				if (patches.length)
				{
					WorkspaceEdit edit;
					edit.changes[file] = patches.map!(a => TextEdit(TextRange(document.bytesToPosition(a.range[0]),
							document.bytesToPosition(a.range[1])), a.content)).array;
					rpc.sendMethod("workspace/applyEdit", ApplyWorkspaceEditParams(edit));
				}
			}
		}
	}
}

@protocolNotification("workspace/didChangeWorkspaceFolders")
void didChangeWorkspaceFolders(DidChangeWorkspaceFoldersParams params)
{
	foreach (toRemove; params.event.removed)
		removeWorkspace(toRemove.uri);
	foreach (toAdd; params.event.added)
	{
		workspaces ~= Workspace(toAdd);
		syncConfiguration(toAdd.uri);
		doStartup(toAdd.uri);
	}
}

@protocolNotification("textDocument/didOpen")
void onDidOpenDocument(DidOpenTextDocumentParams params)
{
	freshlyOpened[params.textDocument.uri] = FileOpenInfo(Clock.currTime);
}

int changeTimeout;
@protocolNotification("textDocument/didChange")
void onDidChangeDocument(DocumentLinkParams params)
{
	auto document = documents[params.textDocument.uri];
	if (document.languageId != "d")
		return;
	int delay = document.text.length > 50 * 1024 ? 1000 : 200; // be slower after 50KiB
	clearTimeout(changeTimeout);
	changeTimeout = setTimeout({
		import served.linters.dscanner;

		lint(document);
		// Delay to avoid too many requests
	}, delay);
}

@protocolNotification("textDocument/didSave")
void onDidSaveDocument(DidSaveTextDocumentParams params)
{
	auto workspaceRoot = workspaceRootFor(params.textDocument.uri);
	auto config = workspace(params.textDocument.uri).config;
	auto document = documents[params.textDocument.uri];
	auto fileName = params.textDocument.uri.uriToFile.baseName;

	if (document.languageId == "d" || document.languageId == "diet")
	{
		if (!config.d.enableLinting)
			return;
		joinAll({
			if (config.d.enableStaticLinting)
			{
				if (document.languageId == "diet")
					return;
				import served.linters.dscanner;

				lint(document);
			}
		}, {
			if (backend.has!DubComponent && config.d.enableDubLinting)
			{
				import served.linters.dub;

				lint(document);
			}
		});
	}
	else if (fileName == "dub.json" || fileName == "dub.sdl")
	{
		info("Updating dependencies");
		rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot).upgrade(),
				MessageType.warning, translate!"d.ext.dubUpgradeFail");
		rpc.window.runOrMessage(backend.get!DubComponent(workspaceRoot)
				.updateImportPaths(true), MessageType.warning, translate!"d.ext.dubImportFail");
		rpc.notifyMethod("coded/updateDubTree");
	}
}

@protocolNotification("served/killServer")
void killServer()
{
	foreach (instance; backend.instances)
		if (instance.has!DCDComponent)
			instance.get!DCDComponent.killServer();
}

@protocolNotification("served/installDependency")
void installDependency(InstallRequest req)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	injectDependency(workspaceRoot, req);
	if (backend.has!DubComponent)
	{
		backend.get!DubComponent(workspaceRoot).upgrade();
		backend.get!DubComponent(workspaceRoot).updateImportPaths(true);
	}
	updateImports();
}

@protocolNotification("served/updateDependency")
void updateDependency(UpdateRequest req)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	if (changeDependency(workspaceRoot, req))
	{
		if (backend.has!DubComponent)
		{
			backend.get!DubComponent(workspaceRoot).upgrade();
			backend.get!DubComponent(workspaceRoot).updateImportPaths(true);
		}
		updateImports();
	}
}

@protocolNotification("served/uninstallDependency")
void uninstallDependency(UninstallRequest req)
{
	auto workspaceRoot = selectedWorkspaceRoot;
	// TODO: add workspace argument
	removeDependency(workspaceRoot, req.name);
	if (backend.has!DubComponent)
	{
		backend.get!DubComponent(workspaceRoot).upgrade();
		backend.get!DubComponent(workspaceRoot).updateImportPaths(true);
	}
	updateImports();
}

void injectDependency(string workspaceRoot, InstallRequest req)
{
	auto sdl = buildPath(workspaceRoot, "dub.sdl");
	if (fs.exists(sdl))
	{
		int depth = 0;
		auto content = fs.readText(sdl).splitLines(KeepTerminator.yes);
		auto insertAt = content.length;
		bool gotLineEnding = false;
		string lineEnding = "\n";
		foreach (i, line; content)
		{
			if (!gotLineEnding && line.length >= 2)
			{
				lineEnding = line[$ - 2 .. $];
				if (lineEnding[0] != '\r')
					lineEnding = line[$ - 1 .. $];
				gotLineEnding = true;
			}
			if (depth == 0 && line.strip.startsWith("dependency "))
				insertAt = i + 1;
			depth += line.count('{') - line.count('}');
		}
		content = content[0 .. insertAt] ~ ((insertAt == content.length ? lineEnding
				: "") ~ "dependency \"" ~ req.name ~ "\" version=\"~>" ~ req.version_ ~ "\"" ~ lineEnding)
			~ content[insertAt .. $];
		fs.write(sdl, content.join());
	}
	else
	{
		auto json = buildPath(workspaceRoot, "dub.json");
		if (!fs.exists(json))
			json = buildPath(workspaceRoot, "package.json");
		if (!fs.exists(json))
			return;
		auto content = fs.readText(json).splitLines(KeepTerminator.yes);
		auto insertAt = content.length ? content.length - 1 : 0;
		string lineEnding = "\n";
		bool gotLineEnding = false;
		int depth = 0;
		bool insertNext;
		string indent;
		bool foundBlock;
		foreach (i, line; content)
		{
			if (!gotLineEnding && line.length >= 2)
			{
				lineEnding = line[$ - 2 .. $];
				if (lineEnding[0] != '\r')
					lineEnding = line[$ - 1 .. $];
				gotLineEnding = true;
			}
			if (insertNext)
			{
				indent = line[0 .. $ - line.stripLeft.length];
				insertAt = i + 1;
				break;
			}
			if (depth == 1 && line.strip.startsWith(`"dependencies":`))
			{
				foundBlock = true;
				if (line.strip.endsWith("{"))
				{
					indent = line[0 .. $ - line.stripLeft.length];
					insertAt = i + 1;
					break;
				}
				else
				{
					insertNext = true;
				}
			}
			depth += line.count('{') - line.count('}') + line.count('[') - line.count(']');
		}
		if (foundBlock)
		{
			content = content[0 .. insertAt] ~ (
					indent ~ indent ~ `"` ~ req.name ~ `": "~>` ~ req.version_ ~ `",` ~ lineEnding)
				~ content[insertAt .. $];
			fs.write(json, content.join());
		}
		else if (content.length)
		{
			if (content.length > 1)
				content[$ - 2] = content[$ - 2].stripRight;
			content = content[0 .. $ - 1] ~ (
					"," ~ lineEnding ~ `	"dependencies": {
		"` ~ req.name ~ `": "~>` ~ req.version_ ~ `"
	}` ~ lineEnding)
				~ content[$ - 1 .. $];
			fs.write(json, content.join());
		}
		else
		{
			content ~= `{
	"dependencies": {
		"` ~ req.name ~ `": "~>` ~ req.version_ ~ `"
	}
}`;
			fs.write(json, content.join());
		}
	}
}

bool changeDependency(string workspaceRoot, UpdateRequest req)
{
	auto sdl = buildPath(workspaceRoot, "dub.sdl");
	if (fs.exists(sdl))
	{
		int depth = 0;
		auto content = fs.readText(sdl).splitLines(KeepTerminator.yes);
		size_t target = size_t.max;
		foreach (i, line; content)
		{
			if (depth == 0 && line.strip.startsWith("dependency ")
					&& line.strip["dependency".length .. $].strip.startsWith('"' ~ req.name ~ '"'))
			{
				target = i;
				break;
			}
			depth += line.count('{') - line.count('}');
		}
		if (target == size_t.max)
			return false;
		auto ver = content[target].indexOf("version");
		if (ver == -1)
			return false;
		auto quotStart = content[target].indexOf("\"", ver);
		if (quotStart == -1)
			return false;
		auto quotEnd = content[target].indexOf("\"", quotStart + 1);
		if (quotEnd == -1)
			return false;
		content[target] = content[target][0 .. quotStart] ~ '"' ~ req.version_ ~ '"'
			~ content[target][quotEnd .. $];
		fs.write(sdl, content.join());
		return true;
	}
	else
	{
		auto json = buildPath(workspaceRoot, "dub.json");
		if (!fs.exists(json))
			json = buildPath(workspaceRoot, "package.json");
		if (!fs.exists(json))
			return false;
		auto content = fs.readText(json);
		auto replaced = content.replaceFirst(regex(`("` ~ req.name ~ `"\s*:\s*)"[^"]*"`),
				`$1"` ~ req.version_ ~ `"`);
		if (content == replaced)
			return false;
		fs.write(json, replaced);
		return true;
	}
}

bool removeDependency(string workspaceRoot, string name)
{
	auto sdl = buildPath(workspaceRoot, "dub.sdl");
	if (fs.exists(sdl))
	{
		int depth = 0;
		auto content = fs.readText(sdl).splitLines(KeepTerminator.yes);
		size_t target = size_t.max;
		foreach (i, line; content)
		{
			if (depth == 0 && line.strip.startsWith("dependency ")
					&& line.strip["dependency".length .. $].strip.startsWith('"' ~ name ~ '"'))
			{
				target = i;
				break;
			}
			depth += line.count('{') - line.count('}');
		}
		if (target == size_t.max)
			return false;
		fs.write(sdl, (content[0 .. target] ~ content[target + 1 .. $]).join());
		return true;
	}
	else
	{
		auto json = buildPath(workspaceRoot, "dub.json");
		if (!fs.exists(json))
			json = buildPath(workspaceRoot, "package.json");
		if (!fs.exists(json))
			return false;
		auto content = fs.readText(json);
		auto replaced = content.replaceFirst(regex(`"` ~ name ~ `"\s*:\s*"[^"]*"\s*,\s*`), "");
		if (content == replaced)
			replaced = content.replaceFirst(regex(`\s*,\s*"` ~ name ~ `"\s*:\s*"[^"]*"`), "");
		if (content == replaced)
			replaced = content.replaceFirst(regex(
					`"dependencies"\s*:\s*\{\s*"` ~ name ~ `"\s*:\s*"[^"]*"\s*\}\s*,\s*`), "");
		if (content == replaced)
			replaced = content.replaceFirst(regex(
					`\s*,\s*"dependencies"\s*:\s*\{\s*"` ~ name ~ `"\s*:\s*"[^"]*"\s*\}`), "");
		if (content == replaced)
			return false;
		fs.write(json, replaced);
		return true;
	}
}

struct Timeout
{
	StopWatch sw;
	Duration timeout;
	void delegate() callback;
	int id;
}

int setTimeout(void delegate() callback, int ms)
{
	return setTimeout(callback, ms.msecs);
}

void setImmediate(void delegate() callback)
{
	setTimeout(callback, 0);
}

int setTimeout(void delegate() callback, Duration timeout)
{
	trace("Setting timeout for ", timeout);
	Timeout to;
	to.timeout = timeout;
	to.callback = callback;
	to.sw.start();
	to.id = ++timeoutID;
	synchronized (timeoutsMutex)
		timeouts ~= to;
	return to.id;
}

void clearTimeout(int id)
{
	synchronized (timeoutsMutex)
		foreach_reverse (i, ref timeout; timeouts)
		{
			if (timeout.id == id)
			{
				timeout.sw.stop();
				if (timeouts.length > 1)
					timeouts[i] = timeouts[$ - 1];
				timeouts.length--;
				return;
			}
		}
}

__gshared void delegate(void delegate()) spawnFiber;

shared static this()
{
	spawnFiber = (&setImmediate).toDelegate;
	backend = new WorkspaceD();

	backend.onBroadcast = (&handleBroadcast).toDelegate;
	backend.onBindFail = (WorkspaceD.Instance instance, ComponentFactory factory) {
		rpc.window.showErrorMessage(
				"Failed to load component " ~ factory.info.name ~ " for workspace " ~ instance.cwd);
	};
}

__gshared int timeoutID;
__gshared Timeout[] timeouts;
__gshared Mutex timeoutsMutex;

// Called at most 100x per second
void parallelMain()
{
	timeoutsMutex = new Mutex;
	while (true)
	{
		synchronized (timeoutsMutex)
			foreach_reverse (i, ref timeout; timeouts)
			{
				if (timeout.sw.peek >= timeout.timeout)
				{
					timeout.sw.stop();
					timeout.callback();
					trace("Calling timeout");
					if (timeouts.length > 1)
						timeouts[i] = timeouts[$ - 1];
					timeouts.length--;
				}
			}
		Fiber.yield();
	}
}
