import core.time;
import core.memory;

import std.algorithm.searching;
import std.array;
import std.base64;
import std.digest;
import file = std.file;
import std.format;
import std.getopt;
import std.json;
import std.math;
import std.net.curl;
import std.parallelism;
import std.path;
import std.uni;
import std.uuid;
import std.zip;

import vibe.core.core;
import vibe.http.websockets;
import vibe.http.server;
import vibe.http.router;
import vibe.stream.tls;
import vibe.web.web;

import slf4d;
import slf4d: Logger;
import slf4d.default_provider;

import provision;
import provision.androidlibrary;

__gshared string libraryPath;

enum brandingCode = format!"anisette-v3-server v%s"(provisionVersion);
enum clientInfo = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>";
enum dsId = -2;

__gshared ADI v1Adi;
__gshared Device v1Device;

__gshared Duration timeout;

int main(string[] args) {
	debug {
		configureLoggingProvider(new shared DefaultProvider(true, Levels.DEBUG));
	} else {
		configureLoggingProvider(new shared DefaultProvider(true, Levels.INFO));
	}

	Logger log = getLogger();
	log.info(brandingCode);
	string hostname = "0.0.0.0";
	ushort port = 6969;

	string configurationPath = expandTilde("~/.config/anisette-v3");

	string certificateChainPath = null;
	string privateKeyPath = null;

	long timeoutMsecs = 3000;

	auto helpInformation = getopt(
		args,
		"n|host", format!"The hostname to bind to (default: %s)"(hostname), &hostname,
		"p|port", format!"The port to bind to (default: %s)"(port), &port,
		"a|adi-path", format!"Where the provisioning information should be stored on the computer for anisette-v1 backwards compat (default: %s)"(configurationPath), &configurationPath,
		"timeout", format!"Timeout duration for Anisette V3 in milliseconds (default: %d)"(timeoutMsecs), &timeoutMsecs,
		"private-key", "Path to the PEM-formatted private key file for HTTPS support (requires --cert-chain)", &certificateChainPath,
		"cert-chain", "Path to the PEM-formatted certificate chain file for HTTPS support (requires --private-key)", &privateKeyPath,
	);

	timeout = dur!"msecs"(timeoutMsecs);

	if ((certificateChainPath && !privateKeyPath) || (!certificateChainPath && privateKeyPath)) {
		log.error("--certificate-chain and --private-key must both be specified for HTTPS support (they can be both be in the same file though).");
		return 1;
	}

	if (helpInformation.helpWanted) {
		defaultGetoptPrinter("anisette-server with v3 support", helpInformation.options);
		return 0;
	}

	if (!file.exists(configurationPath)) {
		file.mkdirRecurse(configurationPath);
	}

	libraryPath = configurationPath.buildPath("lib");

	string provisioningPathV3 = file.getcwd().buildPath("provisioning");

	if (!file.exists(provisioningPathV3)) {
		file.mkdir(provisioningPathV3);
	}

	auto coreADIPath = libraryPath.buildPath("libCoreADI.so");
	auto SSCPath = libraryPath.buildPath("libstoreservicescore.so");

	if (!(file.exists(coreADIPath) && file.exists(SSCPath))) {
		auto http = HTTP();
		log.info("Downloading libraries from Apple servers...");
		auto apkData = get!(HTTP, ubyte)("https://apps.mzstatic.com/content/android-apple-music-apk/applemusic.apk", http);
		log.info("Done !");
		auto apk = new ZipArchive(apkData);
		auto dir = apk.directory();

		if (!file.exists(libraryPath)) {
			file.mkdirRecurse(libraryPath);
		}

		version (X86_64) {
			enum string architectureIdentifier = "x86_64";
		} else version (X86) {
			enum string architectureIdentifier = "x86";
		} else version (AArch64) {
			enum string architectureIdentifier = "arm64-v8a";
		} else version (ARM) {
			enum string architectureIdentifier = "armeabi-v7a";
		} else {
			static assert(false, "Architecture not supported :(");
		}

		file.write(coreADIPath, apk.expand(dir["lib/" ~ architectureIdentifier ~ "/libCoreADI.so"]));
		file.write(SSCPath, apk.expand(dir["lib/" ~ architectureIdentifier ~ "/libstoreservicescore.so"]));
	}

	// Initializing ADI and machine if it has not already been made.
	v1Device = new Device(configurationPath.buildPath("device.json"));
	v1Adi = new ADI(libraryPath);
	v1Adi.provisioningPath = configurationPath;

	if (!v1Device.initialized) {
		log.info("Creating machine... ");

		import std.random;
		import std.range;
		v1Device.serverFriendlyDescription = clientInfo;
		v1Device.uniqueDeviceIdentifier = randomUUID().toString().toUpper();
		v1Device.adiIdentifier = (cast(ubyte[]) rndGen.take(2).array()).toHexString().toLower();
		v1Device.localUserUUID = (cast(ubyte[]) rndGen.take(8).array()).toHexString().toUpper();

		log.info("Machine creation done!");
	}

	v1Adi.identifier = v1Device.adiIdentifier;
	if (!v1Adi.isMachineProvisioned(dsId)) {
		log.info("Machine requires provisioning... ");

		ProvisioningSession provisioningSession = new ProvisioningSession(v1Adi, v1Device);
		provisioningSession.provision(dsId);
		log.info("Provisioning done!");
	}


	// Create the router that will map the incoming requests to request handlers
	auto router = new URLRouter();
	// Register SampleService as a web service
	router.registerWebInterface(new AnisetteService());

	// Start up the HTTP server.
	auto settings = new HTTPServerSettings;
	settings.port = port;
	settings.bindAddresses = [hostname];
	settings.sessionStore = new MemorySessionStore;
	if (certificateChainPath) {
		settings.tlsContext = createTLSContext(TLSContextKind.server);
		settings.tlsContext.useCertificateChainFile(certificateChainPath);
		settings.tlsContext.usePrivateKeyFile(privateKeyPath);
	}

	auto listener = listenHTTP(settings, router);

	return runApplication(&args);
}

class AnisetteService {
	@method(HTTPMethod.GET)
	@path("/")
	void handleV1Request(HTTPServerRequest req, HTTPServerResponse res) {
		import std.datetime.systime;
		import std.datetime.timezone;
		import core.time;
		auto log = getLogger();
		log.info("[<<] anisette-v1 request");
		auto time = Clock.currTime();

		auto otp = v1Adi.requestOTP(dsId);

		import std.conv;
		import std.json;

		JSONValue responseJson = [
			"X-Apple-I-Client-Time": time.toISOExtString.split('.')[0] ~ "Z",
			"X-Apple-I-MD":  Base64.encode(otp.oneTimePassword),
			"X-Apple-I-MD-M": Base64.encode(otp.machineIdentifier),
			"X-Apple-I-MD-RINFO": to!string(17106176),
			"X-Apple-I-MD-LU": v1Device.localUserUUID,
			"X-Apple-I-SRL-NO": "0",
			"X-MMe-Client-Info": v1Device.serverFriendlyDescription,
			"X-Apple-I-TimeZone": time.timezone.dstName,
			"X-Apple-Locale": "en_US",
			"X-Mme-Device-Id": v1Device.uniqueDeviceIdentifier,
		];

		res.headers["Implementation-Version"] = brandingCode;
		res.writeBody(responseJson.toString(JSONOptions.doNotEscapeSlashes), "application/json");
		log.infoF!"[>>] 200 OK %s"(responseJson);
	}

	@method(HTTPMethod.GET)
	@path("/v3/client_info")
	void getClientInfo(HTTPServerRequest req, HTTPServerResponse res) {
		auto log = getLogger();
		log.info("[<<] anisette-v3 /v3/client_info");
		JSONValue responseJson = [
			"client_info": clientInfo,
			"user_agent": "akd/1.0 CFNetwork/808.1.4"
		];

		res.headers["Implementation-Version"] = brandingCode;
		res.writeBody(responseJson.toString(JSONOptions.doNotEscapeSlashes), "application/json");
	}

	@method(HTTPMethod.POST)
	@path("/v3/get_headers")
	void getHeaders(HTTPServerRequest req, HTTPServerResponse res) {
		auto log = getLogger();
		log.info("[<<] anisette-v3 /v3/get_headers");
		string identifier = "(null)";
		try {
			import std.uuid;
			auto json = req.json();
			ubyte[] identifierBytes = Base64.decode(json["identifier"].to!string());
			ubyte[] adi_pb = Base64.decode(json["adi_pb"].to!string());
			identifier = UUID(identifierBytes[0..16]).toString();

			auto provisioningPath = file.getcwd()
				.buildPath("provisioning")
				.buildPath(identifier);

			if (file.exists(provisioningPath)) {
				file.rmdirRecurse(provisioningPath);
			}

			file.mkdir(provisioningPath);
			file.write(provisioningPath.buildPath("adi.pb"), adi_pb);

			GC.disable(); // garbage collector can deallocate ADI parts since it can't find the pointers.
			scope(exit) {
				GC.enable();
				GC.collect();
			}

			ADI adi = makeGarbageCollectedADI(libraryPath);
			adi.provisioningPath = provisioningPath;
			adi.identifier = identifier.toUpper()[0..16];

			auto otp = adi.requestOTP(dsId);
			file.rmdirRecurse(provisioningPath);

			JSONValue response = [ // Provision does no longer have a concept of 'request headers'
				"result": "Headers",
				"X-Apple-I-MD":  Base64.encode(otp.oneTimePassword),
				"X-Apple-I-MD-M": Base64.encode(otp.machineIdentifier),
				"X-Apple-I-MD-RINFO": "17106176",
			];
			res.headers["Implementation-Version"] = brandingCode;
			res.writeBody(response.toString(JSONOptions.doNotEscapeSlashes), "application/json");
			log.info("[>>] anisette-v3 /v3/get_headers OK.");
		} catch (Throwable t) {
			JSONValue error = [
				"result": "GetHeadersError",
				"message": typeid(t).name ~ ": " ~ t.msg
			];
			res.headers["Implementation-Version"] = brandingCode;
			log.info("[>>] anisette-v3 /v3/get_headers error.");
			res.writeBody(error.toString(JSONOptions.doNotEscapeSlashes), "application/json");
		} finally {
			if (file.exists(
				file.getcwd()
				.buildPath("provisioning")
				.buildPath(identifier)
			)) {
				file.rmdirRecurse(
					file.getcwd()
					.buildPath("provisioning")
					.buildPath(identifier)
				);
			}
		}
	}

	@method(HTTPMethod.GET)
	@path("/v3/provisioning_session")
	void provisionSession(scope WebSocket socket) {
		auto log = getLogger();
		scope(exit) socket.close();

		auto requestUUID = randomUUID().toString(); // Assign a random UUID to the request to make it easier to track.
		log.infoF!"[<< %s] anisette-v3 /v3/provisionSession connected."(requestUUID);

		JSONValue giveIdentifier = [
			"result": "GiveIdentifier"
		];
		socket.send(giveIdentifier.toString(JSONOptions.doNotEscapeSlashes));

		log.infoF!"[>> %s] Asking for identifier."(requestUUID);
		if (!socket.waitForData(timeout)) {
			JSONValue timeoutJs = [
				"result": "Timeout"
			];
			log.infoF!"[>> %s] Timeout!"(requestUUID);
			socket.send(timeoutJs.toString(JSONOptions.doNotEscapeSlashes));
			socket.close();
			return;
		}

		string identifier;
		try {
			auto res = parseJSON(socket.receiveText());
			ubyte[] requestedIdentifier = Base64.decode(res["identifier"].str());
			log.infoF!"[>> %s] Got it."(requestUUID);

			identifier = UUID(requestedIdentifier[0..16]).toString();
		} catch (Exception ex) {
			JSONValue response = [
				"result": "InvalidIdentifier"
			];

			log.infoF!"[>> %s] It is invalid: %s"(requestUUID, ex);
			socket.send(response.toString(JSONOptions.doNotEscapeSlashes));
			socket.close();
			return;
		}

		log.infoF!("[<< %s] Correct identifier (%s).")(requestUUID, identifier);

		GC.disable(); // garbage collector can deallocate ADI parts since it can't find the pointers.
		scope(exit) {
			GC.enable();
			GC.collect();
		}
		ADI adi = makeGarbageCollectedADI(libraryPath);
		auto provisioningPath = file.getcwd()
			.buildPath("provisioning")
			.buildPath(identifier);
		adi.provisioningPath = provisioningPath;
		scope(exit) {
			if (file.exists(provisioningPath)) {
				file.rmdirRecurse(provisioningPath);
			}
		}
		adi.identifier = identifier.toUpper()[0..16];

		JSONValue response = [
			"result": "GiveStartProvisioningData"
		];
		log.infoF!"[>> %s] Okay asking for spim now."(requestUUID);

		socket.send(response.toString(JSONOptions.doNotEscapeSlashes));

		if (!socket.waitForData(timeout)) {
			JSONValue timeoutJs = [
				"result": "Timeout"
			];
			log.infoF!"[>> %s] Timeout!"(requestUUID);
			socket.send(timeoutJs.toString(JSONOptions.doNotEscapeSlashes));
			socket.close();
			return;
		}

		uint session;
		try {
			auto res = parseJSON(socket.receiveText());

			string spim = res["spim"].str();
			log.infoF!"[<< %s] Received SPIM."(requestUUID);
			auto cpimAndCo = adi.startProvisioning(-2, Base64.decode(spim));
			session = cpimAndCo.session;

			response = [
				"result": "GiveEndProvisioningData",
				"cpim": Base64.encode(cpimAndCo.clientProvisioningIntermediateMetadata)
			];
			log.infoF!"[>> %s] Okay gimme ptm tk."(requestUUID);

			socket.send(response.toString(JSONOptions.doNotEscapeSlashes));
		} catch (Exception ex) {
			JSONValue error = [
				"result": "StartProvisioningError",
				"message": format!"%s (request id: %s)"(ex.msg, requestUUID)
			];
			log.errorF!"[>> %s] anisette-v3 error: %s"(requestUUID, ex);
			socket.send(error.toString());
			return;
		}


		if (!socket.waitForData(timeout)) {
			JSONValue timeoutJs = [
				"result": "Timeout"
			];
			log.infoF!"[>> %s] Timeout!"(requestUUID);
			socket.send(timeoutJs.toString(JSONOptions.doNotEscapeSlashes));
			socket.close();
			return;
		}

		try {
			auto res = parseJSON(socket.receiveText());
			string ptm = res["ptm"].str();
			string tk = res["tk"].str();
			log.infoF!"[<< %s] Received PTM and TK."(requestUUID);

			adi.endProvisioning(session, Base64.decode(ptm), Base64.decode(tk));

			response = [
				"result": "ProvisioningSuccess",
				"adi_pb": Base64.encode(
					cast(ubyte[]) file.read(
						adi.provisioningPath()
						.buildPath("adi.pb")
					)
				)
			];
		} catch (Exception ex) {
			JSONValue error = [
				"result": "EndProvisioningError",
				"message": format!"%s (request id: %s)"(ex.msg, requestUUID)
			];
			log.errorF!"[>> %s] anisette-v3 error: %s"(requestUUID, ex);
			socket.send(error.toString());
			return;
		}

		log.infoF!"[>> %s] Okay all right here is your provisioning data."(requestUUID);
		socket.send(response.toString(JSONOptions.doNotEscapeSlashes));
	}
}

private ADI makeGarbageCollectedADI(string libraryPath) {
	extern(C) void* malloc_GC(size_t sz) {
		return GC.malloc(sz, GC.BlkAttr.NO_MOVE);
	}

	extern(C) void free_GC(void* ptr) {
		GC.free(ptr);
	}

	AndroidLibrary storeServicesCore = new AndroidLibrary(libraryPath.buildPath("libstoreservicescore.so"), [
		"malloc": cast(void*) &malloc_GC,
		"free": cast(void*) &free_GC
	]);

	return new ADI(libraryPath, storeServicesCore);
}
