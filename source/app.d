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
import std.zip;

import hunt.http;

import slf4d;
import slf4d.default_provider;

import provision;

__gshared ADI adi;
__gshared Device device;
__gshared string libraryPath;

void main(string[] args)
{
	debug {
		configureLoggingProvider(new shared DefaultProvider(true, Levels.DEBUG));
	} else {
		configureLoggingProvider(new shared DefaultProvider(true, Levels.INFO));
	}

	enum brandingCode = format!"anisette-v3-server v%s"(provisionVersion);
	enum clientInfo = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>";

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
	device = new Device(configurationPath.buildPath("device.json"));
	adi = new ADI(libraryPath);
	adi.provisioningPath = configurationPath;

	if (!device.initialized) {
		log.info("Creating machine... ");

		import std.digest;
		import std.random;
		import std.range;
		import std.uni;
		import std.uuid;
		device.serverFriendlyDescription = clientInfo;
		device.uniqueDeviceIdentifier = randomUUID().toString().toUpper();
		device.adiIdentifier = (cast(ubyte[]) rndGen.take(2).array()).toHexString().toLower();
		device.localUserUUID = (cast(ubyte[]) rndGen.take(8).array()).toHexString().toUpper();

		log.info("Machine creation done!");
	}

	enum dsId = -2;

	adi.identifier = device.adiIdentifier;
	if (!adi.isMachineProvisioned(dsId)) {
		log.info("Machine requires provisioning... ");

		ProvisioningSession provisioningSession = new ProvisioningSession(adi, device);
		provisioningSession.provision(dsId);
		log.info("Provisioning done!");
	}

	auto server = HttpServer.builder()
	.setListener(port, hostname)
	.addRoute("/", (RoutingContext context) {
		import std.datetime.systime;
		import std.datetime.timezone;
		import core.time;
		log.info("[<<] anisette-v1 request");
		auto time = Clock.currTime();

		auto otp = adi.requestOTP(dsId);

		import std.conv;
		import std.json;

		JSONValue response = [
			"X-Apple-I-Client-Time": time.toISOExtString.split('.')[0] ~ "Z",
			"X-Apple-I-MD":  Base64.encode(otp.oneTimePassword),
			"X-Apple-I-MD-M": Base64.encode(otp.machineIdentifier),
			"X-Apple-I-MD-RINFO": to!string(17106176),
			"X-Apple-I-MD-LU": device.localUserUUID,
			"X-Apple-I-SRL-NO": "0",
			"X-MMe-Client-Info": device.serverFriendlyDescription,
			"X-Apple-I-TimeZone": time.timezone.dstName,
			"X-Apple-Locale": "en_US",
			"X-Mme-Device-Id": device.uniqueDeviceIdentifier,
		];
		context.responseHeader(HttpHeader.CONTENT_TYPE, "application/json");
		context.responseHeader("Implementation-Version", brandingCode);
		context.write(response.toString(JSONOptions.doNotEscapeSlashes));
		context.end();
		log.infoF!"[>>] 200 OK %s"(response);
	})
	.addRoute("/v3/client_info", (RoutingContext context) {
		JSONValue response = [
			"client_info": clientInfo,
			"user_agent": "akd/1.0 CFNetwork/1404.0.5 Darwin/22.3.0"
		];
		context.write(response.toString());
		context.end();
	})
	.addRoute("/v3/client_info", (RoutingContext context) {
		try {
			if (context.getMethod() == "POST") {
				auto json = parseJSON(context.getStringBody());
				string identifier = json["identifier"].str();
				ubyte[] adi_pb = Base64.decode(json["adi_pb"].str());
				auto provisioningPath = file.getcwd()
				.buildPath("provisioning")
				.buildPath(adi.identifier);
				file.mkdir(provisioningPath);
				file.write(provisioningPath.buildPath("adi.pb"), adi_pb);
				ADI adi = new ADI(libraryPath);
				adi.provisioningPath = provisioningPath;

				auto otp = adi.requestOTP(dsId);
				file.rmdirRecurse(provisioningPath);

				JSONValue response = [ // Provision does no longer have a concept of 'request headers'
					"result": "Headers",
					"X-Apple-I-MD":  Base64.encode(otp.oneTimePassword),
					"X-Apple-I-MD-M": Base64.encode(otp.machineIdentifier),
					"X-Apple-I-MD-RINFO": "17106176",
				];
				context.write(response.toString());
			}
		} catch (Throwable t) {
			JSONValue error = [
				"result": "NonStandard-" ~ typeid(t).name,
				"message": t.msg
			];
			context.write(error.toString());
		} finally {
			context.end();
		}
	})
	.websocket("/v3/provisioning_session", new SocketProvisioningSessionHandler()).build();

	server.start();
}

enum SocketProvisioningSessionState {
	waitingForIdentifier,
	waitingForStartProvisioningData,
	waitingForEndProvisioning,
}

struct SocketProvisioningSession {
	SocketProvisioningSessionState state;
	ADI adiHandle;
	uint session;
}

class SocketProvisioningSessionHandler: AbstractWebSocketMessageHandler {
	SocketProvisioningSession[WebSocketConnection] sessions;

	override void onOpen(WebSocketConnection connection) {
		sessions[connection] = SocketProvisioningSession(SocketProvisioningSessionState.waitingForIdentifier, null, 0);
		JSONValue giveIdentifier = [
			"result": "GiveIdentifier"
		];
		connection.sendText(giveIdentifier.toString());
	}

	override void onClosed(WebSocketConnection connection) {
		auto session = connection in sessions;
		if (session) {
			if (session.adiHandle) {
				ADI adi = session.adiHandle;
				if (file.exists(
					file.getcwd()
					.buildPath("provisioning")
					.buildPath(adi.identifier)
				)) {
					file.rmdirRecurse(
						file.getcwd()
						.buildPath("provisioning")
						.buildPath(adi.identifier)
					);
				}
			}
			sessions.remove(connection);
		}
	}

	override void onText(WebSocketConnection connection, string text) {
		try {
			auto session = connection in sessions;
			final switch (session.state) with (SocketProvisioningSessionState) {
				case waitingForIdentifier:
					auto res = parseJSON(text);
					string requestedIdentifier = res["identifier"].str();
					auto adi = new ADI(libraryPath);
					adi.identifier = requestedIdentifier;
					adi.provisioningPath = file.getcwd().buildPath("provisioning").buildPath(requestedIdentifier);
					session.adiHandle = adi;
					session.state = waitingForStartProvisioningData;
					break;
				case waitingForStartProvisioningData:
					auto res = parseJSON(text);
					string spim = res["spim"].str();
					auto adi = session.adiHandle;
					auto cpimAndCo = adi.startProvisioning(-2, Base64.decode(spim));
					session.session = cpimAndCo.session;
					session.state = waitingForEndProvisioning;
					JSONValue response = [
						"result": "GiveEndProvisioningData",
						"message": Base64.encode(cpimAndCo.clientProvisioningIntermediateMetadata)
					];
					connection.sendText(response.toString());
					break;
				case waitingForEndProvisioning:
					auto res = parseJSON(text);
					string ptm = res["ptm"].str();
					string tk = res["tk"].str();
					auto adi = session.adiHandle;
					adi.endProvisioning(-2, Base64.decode(ptm), Base64.decode(tk));
					JSONValue response = [
						"result": "ProvisioningSuccess",
						"message": Base64.encode(
							cast(ubyte[]) file.read(
								file.getcwd()
									.buildPath("provisioning")
									.buildPath(adi.identifier)
									.buildPath("adi.pb")
							)
						)
					];
					connection.sendText(response.toString()).then((_) {
						connection.close();
					});
					break;
			}
		} catch (Throwable t) {
			JSONValue error = [
				"result": "NonStandard-" ~ typeid(t).name,
				"message": t.msg
			];
			connection.sendText(error.toString()).then((_) {
				connection.close();
			});
		}
	}
}
