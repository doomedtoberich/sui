// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::sync::Arc;

use crate::pipeline::{concurrent::Handler, Processor};
use crate::schema::cp_mapping;
use anyhow::Result;
use diesel::prelude::*;
use diesel_async::RunQueryDsl;
use sui_field_count::FieldCount;
use sui_pg_db::{self as db};
use sui_types::full_checkpoint_content::CheckpointData;

#[derive(Insertable, Selectable, Queryable, Debug, Clone, FieldCount)]
#[diesel(table_name = cp_mapping)]
pub struct StoredCpMapping {
    pub cp_sequence_number: i64,
    pub tx_lo: i64,
    pub epoch: i64,
}

pub struct CpMapping;

pub struct CheckpointMapping {
    from: StoredCpMapping,
    to: StoredCpMapping,
}

impl CheckpointMapping {
    /// Gets the tx and epoch mappings for both the start and end checkpoints.
    ///
    /// The values are expected to exist since the cp_mapping table must have enough information to
    /// encompass the retention of other tables.
    pub async fn get_range(
        conn: &mut Connection<'_>,
        from_cp: u64,
        to_cp: u64,
    ) -> QueryResult<CheckpointMapping> {
        let results = cp_mapping::table
            .select(StoredCpMapping::as_select())
            .filter(cp_mapping::cp.eq_any([from_cp as i64, to_cp as i64]))
            .order(cp_mapping::cp.asc())
            .load::<StoredCpMapping>(conn)
            .await?;

        match results.as_slice() {
            [first, .., last] => Ok(CheckpointMapping {
                from: first.clone(),
                to: last.clone(),
            }),
            _ => Err(diesel::result::Error::NotFound),
        }
    }

    /// Inclusive start and exclusive end range of checkpoints.
    pub fn checkpoint_interval(&self) -> (u64, u64) {
        (self.from.cp as u64, (self.to.cp - 1) as u64)
    }

    /// Inclusive start and exclusive end range of txs. Because the tx_lo in db is inclusive but
    /// tx_hi is exclusive, returns None when encountering an empty range (where tx_lo equals
    /// tx_hi).
    pub fn tx_interval(&self) -> Option<(u64, u64)> {
        if self.from.tx_lo == self.to.tx_hi {
            None
        } else {
            Some((self.from.tx_lo as u64, self.to.tx_hi as u64))
        }
    }

    /// Inclusive start and exclusive end range of epochs.
    pub fn epoch_interval(&self) -> (u64, u64) {
        (self.from.epoch as u64, (self.to.epoch - 1) as u64)
    }
}

impl Processor for CpMapping {
    const NAME: &'static str = "cp_mapping";

    type Value = StoredCpMapping;

    fn process(&self, checkpoint: &Arc<CheckpointData>) -> Result<Vec<Self::Value>> {
        let cp_sequence_number = checkpoint.checkpoint_summary.sequence_number as i64;
        let network_total_transactions =
            checkpoint.checkpoint_summary.network_total_transactions as i64;
        let tx_lo = network_total_transactions - checkpoint.transactions.len() as i64;
        let epoch = checkpoint.checkpoint_summary.epoch as i64;
        Ok(vec![StoredCpMapping {
            cp_sequence_number,
            tx_lo,
            epoch,
        }])
    }
}

#[async_trait::async_trait]
impl Handler for CpMapping {
    async fn commit(values: &[Self::Value], conn: &mut db::Connection<'_>) -> Result<usize> {
        Ok(diesel::insert_into(cp_mapping::table)
            .values(values)
            .on_conflict_do_nothing()
            .execute(conn)
            .await?)
    }
}
