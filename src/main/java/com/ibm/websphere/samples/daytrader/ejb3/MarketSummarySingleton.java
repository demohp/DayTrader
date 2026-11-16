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
package com.ibm.websphere.samples.daytrader.ejb3;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.ObjectInputStream;
import java.io.ObjectOutputStream;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;

import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import jakarta.persistence.TypedQuery;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.CriteriaQuery;
import jakarta.persistence.criteria.Root;

import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.ibm.websphere.samples.daytrader.beans.MarketSummaryDataBean;
import com.ibm.websphere.samples.daytrader.entities.QuoteDataBean;
import com.ibm.websphere.samples.daytrader.util.FinancialUtils;
import com.ibm.websphere.samples.daytrader.util.Log;
import com.ibm.websphere.samples.daytrader.util.TradeConfig;

import redis.clients.jedis.Jedis;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;

/**
 * Singleton component that stores MarketSummaryDataBean state in Azure Cache for Redis
 * instead of JVM-local memory, enabling consistent state across horizontally
 * scaled AKS pods.
 *
 * Redis connection string is injected via the REDIS_CONNECTION_STRING environment
 * variable, which is populated from Azure Key Vault CSI driver secrets in AKS.
 *
 * Remediation for cz-java-0064: Singleton State Storage externalized to Redis.
 * Remediation for cz-java-0081: Replaced server-specific EJB @Singleton, @Lock,
 * @LockType, @Schedule annotations with portable Spring @Component and @Scheduled.
 */
// cz-java-0081: Replaced @Singleton (jakarta.ejb) with Spring @Component for portability.
// cz-java-0081: Replaced @Lock/@LockType (jakarta.ejb) with synchronized methods.
// cz-java-0081: Replaced @Schedule (jakarta.ejb) with Spring @Scheduled.
@Component
public class MarketSummarySingleton {

    private static final String MARKET_SUMMARY_REDIS_KEY = "daytrader:marketSummary";

    /**
     * Redis connection pool backed by Azure Cache for Redis.
     * Connection string is read from the REDIS_CONNECTION_STRING environment
     * variable injected by the Azure Key Vault CSI driver into the AKS pod.
     */
    private JedisPool jedisPool;

    @PersistenceContext
    private EntityManager entityManager;

    @PostConstruct
    private void setup() {
        initRedisPool();
        updateMarketSummary();
    }

    /**
     * Initialises the Jedis connection pool using the REDIS_CONNECTION_STRING
     * environment variable.  Expected format: {@code <host>:<port>} or a full
     * Redis URI ({@code redis://<host>:<port>}).
     */
    private void initRedisPool() {
        String redisConnectionString = System.getenv("REDIS_CONNECTION_STRING");
        if (redisConnectionString == null || redisConnectionString.isEmpty()) {
            Log.debug("MarketSummarySingleton: REDIS_CONNECTION_STRING env var not set; Redis state storage unavailable.");
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
                // Expect host:port format
                String[] parts = redisConnectionString.split(":");
                String host = parts[0];
                int port = parts.length > 1 ? Integer.parseInt(parts[1]) : 6379;
                jedisPool = new JedisPool(poolConfig, host, port);
            }
            Log.debug("MarketSummarySingleton: Redis pool initialised using REDIS_CONNECTION_STRING.");
        } catch (Exception e) {
            Log.debug("MarketSummarySingleton: Failed to initialise Redis pool – " + e.getMessage());
        }
    }

    @PreDestroy
    private void teardown() {
        if (jedisPool != null && !jedisPool.isClosed()) {
            jedisPool.close();
        }
    }

    /* Update Market Summary every 20 seconds */
    // cz-java-0081: Replaced server-specific @Schedule (jakarta.ejb) with portable Spring @Scheduled.
    @Scheduled(fixedDelay = 20000)
    private void updateMarketSummary() {

        if (Log.doTrace()) {
            Log.trace("MarketSummarySingleton:updateMarketSummary -- updating market summary");
        }

        if (TradeConfig.getRunTimeMode() != TradeConfig.EJB3) {
            if (Log.doTrace()) {
                Log.trace("MarketSummarySingleton:updateMarketSummary -- Not EJB3 Mode, so not updating");
            }
            return; // Only do the actual work if in EJB3 Mode
        }

        List<QuoteDataBean> quotes;

        try {
            // Find Trade Stock Index Quotes (Top 100 quotes) ordered by their change in value
            CriteriaBuilder criteriaBuilder = entityManager.getCriteriaBuilder();
            CriteriaQuery<QuoteDataBean> criteriaQuery = criteriaBuilder.createQuery(QuoteDataBean.class);
            Root<QuoteDataBean> quoteRoot = criteriaQuery.from(QuoteDataBean.class);
            criteriaQuery.orderBy(criteriaBuilder.desc(quoteRoot.get("change1")));
            criteriaQuery.select(quoteRoot);
            TypedQuery<QuoteDataBean> q = entityManager.createQuery(criteriaQuery);
            quotes = q.getResultList();
        } catch (Exception e) {
            Log.debug("Warning: The database has not been configured. If this is the first time the application has been started, please create and populate the database tables. Then restart the server.");
            return;
        }

        /* TODO: Make this cleaner? */
        QuoteDataBean[] quoteArray = quotes.toArray(new QuoteDataBean[quotes.size()]);
        ArrayList<QuoteDataBean> topGainers = new ArrayList<QuoteDataBean>(5);
        ArrayList<QuoteDataBean> topLosers = new ArrayList<QuoteDataBean>(5);
        BigDecimal TSIA = FinancialUtils.ZERO;
        BigDecimal openTSIA = FinancialUtils.ZERO;
        double totalVolume = 0.0;

        if (quoteArray.length > 5) {
            for (int i = 0; i < 5; i++) {
                topGainers.add(quoteArray[i]);
            }
            for (int i = quoteArray.length - 1; i >= quoteArray.length - 5; i--) {
                topLosers.add(quoteArray[i]);
            }

            for (QuoteDataBean quote : quoteArray) {
                BigDecimal price = quote.getPrice();
                BigDecimal open = quote.getOpen();
                double volume = quote.getVolume();
                TSIA = TSIA.add(price);
                openTSIA = openTSIA.add(open);
                totalVolume += volume;
            }
            TSIA = TSIA.divide(new BigDecimal(quoteArray.length), FinancialUtils.ROUND);
            openTSIA = openTSIA.divide(new BigDecimal(quoteArray.length), FinancialUtils.ROUND);
        }

        setMarketSummaryDataBean(new MarketSummaryDataBean(TSIA, openTSIA, totalVolume, topGainers, topLosers));
    }

    /**
     * Retrieves the MarketSummaryDataBean from Azure Cache for Redis.
     * Falls back to null if Redis is unavailable.
     * cz-java-0081: Replaced @Lock(LockType.READ) (jakarta.ejb) with synchronized for portability.
     */
    public synchronized MarketSummaryDataBean getMarketSummaryDataBean() {
        if (jedisPool == null) {
            Log.debug("MarketSummarySingleton: Redis pool not available; returning null for market summary.");
            return null;
        }
        try (Jedis jedis = jedisPool.getResource()) {
            byte[] data = jedis.get(MARKET_SUMMARY_REDIS_KEY.getBytes());
            if (data == null) {
                return null;
            }
            try (ObjectInputStream ois = new ObjectInputStream(new ByteArrayInputStream(data))) {
                return (MarketSummaryDataBean) ois.readObject();
            }
        } catch (Exception e) {
            Log.debug("MarketSummarySingleton: Error reading market summary from Redis – " + e.getMessage());
            return null;
        }
    }

    /**
     * Persists the MarketSummaryDataBean to Azure Cache for Redis so that all
     * AKS pod replicas share the same consistent state.
     * cz-java-0081: Replaced @Lock(LockType.WRITE) (jakarta.ejb) with synchronized for portability.
     */
    public synchronized void setMarketSummaryDataBean(MarketSummaryDataBean marketSummaryDataBean) {
        if (jedisPool == null) {
            Log.debug("MarketSummarySingleton: Redis pool not available; market summary state not persisted.");
            return;
        }
        try (Jedis jedis = jedisPool.getResource();
             ByteArrayOutputStream baos = new ByteArrayOutputStream();
             ObjectOutputStream oos = new ObjectOutputStream(baos)) {
            oos.writeObject(marketSummaryDataBean);
            oos.flush();
            jedis.set(MARKET_SUMMARY_REDIS_KEY.getBytes(), baos.toByteArray());
        } catch (Exception e) {
            Log.debug("MarketSummarySingleton: Error writing market summary to Redis – " + e.getMessage());
        }
    }

}
