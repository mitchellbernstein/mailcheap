import mongoose from "mongoose";

const cached = globalThis.__mailcheapMongoose ?? { connection: null, promise: null };
globalThis.__mailcheapMongoose = cached;

export async function connectDb() {
	if (cached.connection) return cached.connection;
	// MONGODB_URL is the name the Vercel MongoDB Atlas integration creates.
	const uri = process.env.MONGODB_URI || process.env.MONGODB_URL;
	if (!uri) throw new Error("MONGODB_URI is not set");

	cached.promise ??= mongoose.connect(uri, {
		maxPoolSize: 10,
		serverSelectionTimeoutMS: 5000,
	});
	cached.connection = await cached.promise;
	return cached.connection;
}
