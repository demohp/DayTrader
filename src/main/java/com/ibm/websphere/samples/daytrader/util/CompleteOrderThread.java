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

import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionStatus;
import org.springframework.transaction.support.DefaultTransactionDefinition;

import com.ibm.websphere.samples.daytrader.TradeServices;
import com.ibm.websphere.samples.daytrader.direct.TradeDirect;
import com.ibm.websphere.samples.daytrader.ejb3.TradeSLSBBean;

public class CompleteOrderThread implements Runnable {

        final Integer orderID;
        boolean twoPhase;
        private final PlatformTransactionManager transactionManager;
        
        
        public CompleteOrderThread (Integer id, boolean twoPhase) {
            orderID = id;
            this.twoPhase = twoPhase;
            this.transactionManager = null;
        }

        public CompleteOrderThread (Integer id, boolean twoPhase, PlatformTransactionManager transactionManager) {
            orderID = id;
            this.twoPhase = twoPhase;
            this.transactionManager = transactionManager;
        }
        
        @Override
        public void run() {
            TradeServices trade;
            TransactionStatus status = null;
            
            try {
                // TODO: Sometimes, rarely, the commit does not complete before the find in completeOrder (leads to null order)
                // Adding delay here for now, will try to find a better solution in the future.
                Thread.sleep(500);

                if (transactionManager != null) {
                    status = transactionManager.getTransaction(new DefaultTransactionDefinition());
                }

                if (TradeConfig.getRunTimeMode() == TradeConfig.EJB3) {
                    trade = new TradeSLSBBean();
                } else {
                    trade = new TradeDirect();
                }
                
                trade.completeOrder(orderID, twoPhase);

                if (transactionManager != null && status != null) {
                    transactionManager.commit(status);
                }
            } catch (Exception e) {
                if (transactionManager != null && status != null) {
                    try {
                        transactionManager.rollback(status);
                    } catch (Exception e1) {
                        throw new RuntimeException(e1);
                    }
                }
                throw new RuntimeException(e);
            } 
        }
}
