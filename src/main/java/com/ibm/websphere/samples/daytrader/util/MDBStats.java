/**
 * (C) Copyright IBM Corporation 2015.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.ibm.websphere.samples.daytrader.util;

import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

/**
 * MDBStats externalises its singleton state to Azure Cache for Redis so that
 * all horizontally scaled AKS pod replicas share a consistent view of MDB
 * timing statistics.
 *
 * The Redis connection string is read from the REDIS_CONNECTION_STRING
 * environment variable, which is injected by the Azure Key Vault CSI driver
 * into each AKS pod at runtime.
 *
 * Remediation for cz-java-0071: Singleton State Storage externalized to
 * Azure Cache for Redis on AKS.
 */
// cz-java-0071 (Lines 33-33): JVM-local static singleton field replaced with
// Azure Cache for Redis-backed state storage to ensure consistency across AKS
// pod replicas. REDIS_CONNECTION_STRING is injected via Azure Key Vault CSI
// Driver into each AKS pod at runtime.
public class MDBStats {

    private static final long serialVersionUID = -3759835921094193760L;

    private static final String REDIS_KEY_PREFIX = "daytrader:mdbstats:";

    /**
     * Shared Redis connection pool. Initialised once via the
     * REDIS_CONNECTION_STRING environment variable injected by the Azure Key
     * Vault CSI driver.
     */
    private static JedisPool jedisPool;

    static {
        initRedisPool();
    }

    // Private constructor – use getInstance() factory method.
    private MDBStats() {
    }

    /**
     * Initialises the shared Jedis connection pool from the
     * REDIS_CONNECTION_STRING environment variable.
     */
    private static void initRedisPool() {
        String redisConnectionString = System.getenv("REDIS_CONNECTION_STRING");
        if (redisConnectionString == null || redisConnectionString.isEmpty()) {
            System.err.println("MDBStats: REDIS_CONNECTION_STRING not set – Redis state storage disabled.");
            return;
        }
        try {
            JedisPoolConfig poolConfig = new JedisPoolConfig();
            poolConfig.setMaxTotal(10);
            poolConfig.setMaxIdle(5);
            poolConfig.setMinIdle(1);
            poolConfig.setTestOnBorrow(true);

            if (redisConnectionString.startsWith("redis://") || redisConnectionString.startsWith("rediss://")) {
                jedisPool = new JedisPool(poolConfig, redisConnectionString);
            } else {
                String[] parts = redisConnectionString.split(":");
                String host = parts[0];
                int port = parts.length > 1 ? Integer.parseInt(parts[1]) : 6379;
                jedisPool = new JedisPool(poolConfig, host, port);
            }
        } catch (Exception e) {
            // Log initialisation failure; fall back to no-op behaviour.
            System.err.println("MDBStats: Failed to initialise Redis pool – " + e.getMessage());
        }
    }

    /**
     * Returns the singleton MDBStats instance.
     * The instance itself carries no mutable state; all state is stored in
     * Azure Cache for Redis.
     */
    public static synchronized MDBStats getInstance() {
        return new MDBStats();
    }

    /**
     * Records timing data for the given message type in Redis.
     * Each stat entry is stored as a Redis hash under the key
     * {@code daytrader:mdbstats:<type>}.
     *
     * @param type     message type identifier
     * @param sendTime message send timestamp (ms)
     * @param recvTime message receive timestamp (ms)
     * @return updated {@link TimerStat} for the given type
     */
    public TimerStat addTiming(String type, long sendTime, long recvTime) {
        double time = (double) (recvTime - sendTime);

        if (jedisPool == null) {
            // Redis unavailable – compute stat locally without persisting.
            TimerStat stats = new TimerStat();
            stats.setMax(time);
            stats.setMin(time);
            stats.setCount(1);
            stats.setTotalTime(time);
            return stats;
        }

        String redisKey = REDIS_KEY_PREFIX + type;
        try (Jedis jedis = jedisPool.getResource()) {
            // Read existing values from Redis hash
            String maxStr       = jedis.hget(redisKey, "max");
            String minStr       = jedis.hget(redisKey, "min");
            String countStr     = jedis.hget(redisKey, "count");
            String totalTimeStr = jedis.hget(redisKey, "totalTime");

            double max       = maxStr       != null ? Double.parseDouble(maxStr)       : 0.0;
            double min       = minStr       != null ? Double.parseDouble(minStr)       : 1000000000.0;
            int    count     = countStr     != null ? Integer.parseInt(countStr)       : 0;
            double totalTime = totalTimeStr != null ? Double.parseDouble(totalTimeStr) : 0.0;

            if (time > max)  { max = time; }
            if (time < min)  { min = time; }
            count++;
            totalTime += time;

            // Persist updated values back to Redis
            jedis.hset(redisKey, "max",       Double.toString(max));
            jedis.hset(redisKey, "min",       Double.toString(min));
            jedis.hset(redisKey, "count",     Integer.toString(count));
            jedis.hset(redisKey, "totalTime", Double.toString(totalTime));

            TimerStat stats = new TimerStat();
            stats.setMax(max);
            stats.setMin(min);
            stats.setCount(count);
            stats.setTotalTime(totalTime);
            return stats;
        } catch (Exception e) {
            System.err.println("MDBStats: Error accessing Redis for type '" + type + "' – " + e.getMessage());
            TimerStat stats = new TimerStat();
            stats.setMax(time);
            stats.setMin(time);
            stats.setCount(1);
            stats.setTotalTime(time);
            return stats;
        }
    }

    /**
     * Resets all MDB timing statistics stored in Redis.
     */
    public synchronized void reset() {
        if (jedisPool == null) {
            return;
        }
        try (Jedis jedis = jedisPool.getResource()) {
            // Remove all keys matching the MDB stats prefix
            java.util.Set<String> keys = jedis.keys(REDIS_KEY_PREFIX + "*");
            if (keys != null && !keys.isEmpty()) {
                jedis.del(keys.toArray(new String[0]));
            }
        } catch (Exception e) {
            System.err.println("MDBStats: Error resetting Redis stats – " + e.getMessage());
        }
    }

}
