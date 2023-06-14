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

import lighttp;

import slf4d;
import slf4d.default_provider;

import provision;

__gshared string libraryPath;

enum brandingCode = format!"anisette-v3-server v%s"(provisionVersion);
enum clientInfo = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>";
enum dsId = -2;

__gshared ADI v1Adi;
__gshared Device v1Device;

void main(string[] args)
{
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
	auto helpInformation = getopt(
		args,
		"n|host", format!"The hostname to bind to (default: %s)"(hostname), &hostname,
		"p|port", format!"The port to bind to (default: %s)"(port), &port,
		"a|adi-path", format!"Where the provisioning information should be stored on the computer for anisette-v1 backwards compat (default: %s)"(configurationPath), &configurationPath,
	);

	if (helpInformation.helpWanted) {
		defaultGetoptPrinter("anisette-server with v3 support", helpInformation.options);
		return;
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

	Server server = new Server();
	server.host(hostname, port);
	server.router.add(new AnisetteUnifiedServer());
	server.run();
	/+
	auto server = HttpServer.builder()
	.setListener(port, hostname)
	.addRoute("/", (RoutingContext context) {
	})
	.addRoute("/v3/client_info", (RoutingContext context) {
	})
	.addRoute("/v3/get_headers", (RoutingContext context) {
	})
	.websocket("/v3/provisioning_session", new SocketProvisioningSessionHandler()).build();

	server.start();
+/
}

class AnisetteUnifiedServer {
	@Get("") handleV1Request(ServerResponse response) {
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

		response.contentType = "application/json";
		response.headers["Implementation-Version"] = brandingCode;
		response.body = responseJson.toString(JSONOptions.doNotEscapeSlashes);
		log.infoF!"[>>] 200 OK %s"(responseJson);
	}

	@Get("v3/client_info") void getClientInfo(ServerResponse response) {
		auto log = getLogger();
		log.info("[<<] anisette-v3 /v3/client_info");
		JSONValue responseJson = [
			"client_info": clientInfo,
			"user_agent": "akd/1.0 CFNetwork/808.1.4"
		];

		response.headers["Implementation-Version"] = brandingCode;
		response.body = responseJson.toString(JSONOptions.doNotEscapeSlashes);
	}

	@Post("v3/get_headers") void getHeaders(ServerResponse res, ServerRequest req) {
		auto log = getLogger();
		log.info("[<<] anisette-v3 /v3/get_headers");
		string identifier = "(null)";
		try {
			import std.uuid;
			auto json = parseJSON(req.body());
			ubyte[] identifierBytes = Base64.decode(json["identifier"].str());
			ubyte[] adi_pb = Base64.decode(json["adi_pb"].str());
			identifier = UUID(identifierBytes[0..16]).toString();
			auto provisioningPath = file.getcwd()
			.buildPath("provisioning")
			.buildPath(identifier);
			file.mkdir(provisioningPath);
			file.write(provisioningPath.buildPath("adi.pb"), adi_pb);
			ADI adi = new ADI(libraryPath);
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
			res.body = response.toString(JSONOptions.doNotEscapeSlashes);
		} catch (Throwable t) {
			JSONValue error = [
				"result": "GetHeadersError",
				"message": typeid(t).name ~ ": " ~ t.msg
			];
			res.headers["Implementation-Version"] = brandingCode;
			res.body = error.toString(JSONOptions.doNotEscapeSlashes);
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

	@Get("v3/provisioning_session") class ProvisioningSocket : WebSocket {
		SocketProvisioningSessionState state;
		ADI adi;
		uint session;

		string ip;

		void onConnect(ServerRequest request) {
			getLogger().info("[<<] anisette-v3 /v3/provisioning_session open");
			state = SocketProvisioningSessionState.waitingForIdentifier;
			adi = null;
			session = 0;
			ip = "";

			JSONValue giveIdentifier = [
				"result": "GiveIdentifier"
			];
			send(giveIdentifier.toString(JSONOptions.doNotEscapeSlashes));
		}

		override void onClose() {
			getLogger().infoF!("[<< %s] anisette-v3 /v3/provisioning_session close")(ip);
		}

		override void onReceive(ubyte[] data) {
			string text = cast(string) data;
			auto log = getLogger();
			try {
				final switch (state) with (SocketProvisioningSessionState) {
					case waitingForIdentifier:
						auto res = parseJSON(text);
						ubyte[] requestedIdentifier = Base64.decode(res["identifier"].str());

						if (requestedIdentifier.length != 16) {
							JSONValue response = [
								"result": "InvalidIdentifier"
							];

							log.infoF!("[>> %s] It is invalid.")(ip);
							send(response.toString());
							return;
						}
						string identifier = UUID(requestedIdentifier[0..16]).toString();
						log.infoF!("[<< %s] Received an identifier (%s).")(ip, identifier);

						adi = new ADI(libraryPath);
						adi.provisioningPath = file.getcwd().buildPath("provisioning").buildPath(identifier);
						adi.identifier = identifier.toUpper()[0..16];
						state = waitingForStartProvisioningData;
						JSONValue response = [
							"result": "GiveStartProvisioningData"
						];
						log.infoF!("[>> %s] Okay gimme spim.")(ip);
						send(response.toString(JSONOptions.doNotEscapeSlashes));
						break;
					case waitingForStartProvisioningData:
						auto res = parseJSON(text);
						string spim = res["spim"].str();
						log.infoF!("[<< %s] Received SPIM.")(ip);
						auto cpimAndCo = adi.startProvisioning(-2, Base64.decode(spim));
						session = cpimAndCo.session;
						state = waitingForEndProvisioning;
						JSONValue response = [
							"result": "GiveEndProvisioningData",
							"cpim": Base64.encode(cpimAndCo.clientProvisioningIntermediateMetadata)
						];
						log.infoF!("[>> %s] Okay gimme ptm tk.")(ip);
						send(response.toString(JSONOptions.doNotEscapeSlashes));
						break;
					case waitingForEndProvisioning:
						auto res = parseJSON(text);
						string ptm = res["ptm"].str();
						string tk = res["tk"].str();
						log.infoF!("[<< %s] Received PTM and TK.")(ip);
						adi.endProvisioning(session, Base64.decode(ptm), Base64.decode(tk));
						JSONValue response = [
							"result": "ProvisioningSuccess",
							"adi_pb": Base64.encode(
								cast(ubyte[]) file.read(
									adi.provisioningPath()
									.buildPath("adi.pb")
								)
							)
						];
						log.infoF!("[>> %s] Okay all right here is your provisioning data.")(ip);
						send(response.toString(JSONOptions.doNotEscapeSlashes));
						break;
					// +/
				}
			} catch (Throwable t) {
				JSONValue error = [
					"result": "NonStandard-" ~ typeid(t).name,
					"message": t.msg
				];
				log.errorF!"[>>] anisette-v3 error: %s"(t);
				// connection.sendText(error.toString()).then((_) {
				// 	connection.close();
				// });
			}
		}
	}
}

enum SocketProvisioningSessionState {
	waitingForIdentifier,
	waitingForStartProvisioningData,
	waitingForEndProvisioning,
}
