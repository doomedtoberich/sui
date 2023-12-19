// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// This module provides functionality for generating secure randomness.
module sui::random {
    use std::bcs;
    use std::vector;
    use sui::event;
    use sui::dynamic_field;
    use sui::address::to_bytes;
    use sui::hmac::hmac_sha3_256;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext, fresh_object_address};
    use sui::versioned::{Self, Versioned};

    // Sender is not @0x0 the system address.
    const ENotSystemAddress: u64 = 0;
    const EWrongRoundsVersion: u64 = 1;
    const EInvalidRandomnessUpdate: u64 = 2;
    const EInvalidRange: u64 = 3;
    const ERoundNotAvailableYet: u64 = 4;
    const ERoundTooOld: u64 = 5;

    const CURRENT_VERSION: u64 = 1;
    const RAND_OUTPUT_LEN: u16 = 32;

    // TODO: changes/assumptions on the Sui side:
    // 1. Rounds are increasing monotonically also betweeen epochs (can also be done here if needed).
    // 2. guarantee that the last sent partial sig is committed after EoP (but not to generate more).
    // 3. first round is 1 (though can be handled here if needed).


    ///
    /// Global randomness state.
    ///

    /// Singleton shared object which stores the global randomness state.
    /// The actual state is stored in a versioned inner field.
    struct Random has key {
        id: UID,
        rounds: Versioned,
    }

    /// Container for historical randomness values.
    struct Rounds has store {
        id: UID,
        version: u64,

        max_size: u64,
        oldest_round: u64,
        latest_round: u64,
        // The actual randomness must never be accessed outside this module as it could be used for accessing global
        // randomness via bcs::to_bytes(). We use dynamic fields to store the randomness values.
    }

    /// Event for new randomness value.
    struct NewRandomness has copy, drop {
        round: u64,
    }

    #[allow(unused_function)]
    /// Create and share the Random object. This function is called exactly once, when
    /// the Random object is first created.
    /// Can only be called by genesis or change_epoch transactions.
    fun create(ctx: &mut TxContext) {
        assert!(tx_context::sender(ctx) == @0x0, ENotSystemAddress);
        let version = CURRENT_VERSION;
        let rounds = Rounds {
            id: object::randomness_round(), // TODO: what is the right way to do this, another fixed address?
            version,
            max_size: 1,
            oldest_round: 1,
            latest_round: 0,
        };
        let self = Random {
            id: object::randomness_state(),
            rounds: versioned::create(version, rounds, ctx),
        };
        transfer::share_object(self);
    }

    fun load_rounds_mut(
        self: &mut Random,
    ): &mut Rounds {
        let version = versioned::version(&self.rounds);
        // Replace this with a lazy update function when we add a new version of the inner object.
        assert!(version == CURRENT_VERSION, EWrongRoundsVersion);
        let rounds: &mut Rounds = versioned::load_value_mut(&mut self.rounds);
        assert!(rounds.version == version, EWrongRoundsVersion);
        rounds
    }

    fun load_rounds(
        self: &Random,
    ): &Rounds {
        let version = versioned::version(&self.rounds);
        // Replace this with a lazy update function when we add a new version of the inner object.
        assert!(version == CURRENT_VERSION, EWrongRoundsVersion);
        let rounds: &Rounds = versioned::load_value(&self.rounds);
        assert!(rounds.version == version, EWrongRoundsVersion);
        rounds
    }

    fun add_round(r: &mut Rounds, new_max_size: u64, round: u64, value: vector<u8>) {
        assert!(round == r.latest_round + 1, EInvalidRandomnessUpdate);
        r.max_size = new_max_size;
        r.latest_round = round;
        // Remove old rounds if needed.
        while (r.max_size < r.latest_round - r.oldest_round + 1) {
            dynamic_field::remove<u64, vector<u8>>(&mut r.id, r.oldest_round);
            r.oldest_round = r.oldest_round + 1;
        };
        dynamic_field::add(&mut r.id, round, value);
        event::emit(NewRandomness { round });
    }

    fun round_bytes(r: &Rounds, round: u64): &vector<u8> {
        assert!(round >= r.oldest_round, ERoundTooOld);
        assert!(round <= r.latest_round, ERoundNotAvailableYet);
        dynamic_field::borrow(&r.id, round)
    }

    #[allow(unused_function)]
    /// Record new randomness. Called when executing the RandomnessStateUpdate system transaction.
    fun update_randomness_state(
        self: &mut Random,
        new_round: u64,
        new_bytes: vector<u8>,
        new_max_size: u64,
        ctx: &TxContext,
    ) {
        // Validator will make a special system call with sender set as 0x0.
        assert!(tx_context::sender(ctx) == @0x0, ENotSystemAddress);
        let rounds = load_rounds_mut(self);
        add_round(rounds, new_max_size, new_round, new_bytes);
    }

    /// Set of inputs that can be used to create a RandomGenerator
    struct RandomGeneratorRequest has store, drop {
        round: u64,
        seed: vector<u8>,
    }

    /// Create a new request for a unique random generator.
    public fun new_request(r: &Random, ctx: &mut TxContext): RandomGeneratorRequest {
        let rounds = load_rounds(r);
        RandomGeneratorRequest {
            round: rounds.latest_round + 2, // Next round that is safe when the current transaction is executed.
            seed: to_bytes(fresh_object_address(ctx)), // Globally unique (though predictable).
        }
    }

    /// Deterministic construction of a random generator from a request and the global randomness.
    public fun fulfill(req: &RandomGeneratorRequest, r: &Random): RandomGenerator {
        let rounds = load_rounds(r);
        let randomness = round_bytes(rounds, req.round);
        let seed = hmac_sha3_256(randomness, &req.seed);
        RandomGenerator {
            seed,
            counter: 0,
            buffer: vector::empty(),
        }
    }

    public fun is_available(req: &RandomGeneratorRequest, r: &Random): bool {
        let rounds = load_rounds(r);
        req.round >= rounds.oldest_round && req.round <= rounds.latest_round
    }

    public fun is_too_old(req: &RandomGeneratorRequest, r: &Random): bool {
        let rounds = load_rounds(r);
        req.round < rounds.oldest_round
    }

    public fun required_round(req: &RandomGeneratorRequest): u64 {
        req.round
    }


    ///
    /// Unique randomness generator.
    ///

    /// Randomness generator. Maintains an internal buffer of random bytes.
    struct RandomGenerator has drop {
        seed: vector<u8>,
        counter: u16,
        buffer: vector<u8>,
    }

    // Get the next block of random bytes.
    fun derive_next_block(g: &mut RandomGenerator): vector<u8> {
        g.counter = g.counter + 1;
        hmac_sha3_256(&g.seed, &bcs::to_bytes(&g.counter))
    }

    // Fill the generator's buffer with 32 random bytes.
    fun fill_buffer(g: &mut RandomGenerator) {
        let next_block = derive_next_block(g);
        vector::append(&mut g.buffer, next_block);
    }

    /// Generate n random bytes.
    public fun bytes(g: &mut RandomGenerator, num_of_bytes: u16): vector<u8> {
        let result = vector::empty();
        // Append RAND_OUTPUT_LEN size buffers directly without going through the generator's buffer.
        let num_of_blocks = num_of_bytes / RAND_OUTPUT_LEN;
        while (num_of_blocks > 0) {
            vector::append(&mut result, derive_next_block(g));
            num_of_blocks = num_of_blocks - 1;
        };
        // Take remaining bytes from the generator's buffer.
        if (vector::length(&g.buffer) < ((num_of_bytes as u64) - vector::length(&result))) {
            fill_buffer(g);
        };
        while (vector::length(&result) < (num_of_bytes as u64)) {
            vector::push_back(&mut result, vector::pop_back(&mut g.buffer));
        };
        result
    }

    // Helper function that extracts the given number of bytes from the random generator and returns it as u256.
    // Assumes that the caller has already checked that num_of_bytes is valid.
    fun u256_from_bytes(g: &mut RandomGenerator, num_of_bytes: u8): u256 {
        if (vector::length(&g.buffer) < (num_of_bytes as u64)) {
            fill_buffer(g);
        };
        let result: u256 = 0;
        let i = 0;
        while (i < num_of_bytes) {
            let byte = vector::pop_back(&mut g.buffer);
            result = (result << 8) + (byte as u256);
            i = i + 1;
        };
        result
    }

    /// Generate a u256.
    public fun generate_u256(g: &mut RandomGenerator): u256 {
        u256_from_bytes(g, 32)
    }

    /// Generate a u128.
    public fun generate_u128(g: &mut RandomGenerator): u128 {
        (u256_from_bytes(g, 16) as u128)
    }

    /// Generate a u64.
    public fun generate_u64(g: &mut RandomGenerator): u64 {
        (u256_from_bytes(g, 8) as u64)
    }

    /// Generate a u32.
    public fun generate_u32(g: &mut RandomGenerator): u32 {
        (u256_from_bytes(g, 4) as u32)
    }

    /// Generate a u16.
    public fun generate_u16(g: &mut RandomGenerator): u16 {
        (u256_from_bytes(g, 2) as u16)
    }

    /// Generate a u8.
    public fun generate_u8(g: &mut RandomGenerator): u8 {
        (u256_from_bytes(g, 1) as u8)
    }

    // Helper function to generate a random u128 in [min, max] using a random number with num_of_bytes bytes.
    // Assumes that the caller verified the inputs, and uses num_of_bytes to control the bias.
    fun u128_in_range(g: &mut RandomGenerator, min: u128, max: u128, num_of_bytes: u8): u128 {
        assert!(min < max, EInvalidRange);
        let diff = ((max - min) as u256) + 1;
        let rand = u256_from_bytes(g, num_of_bytes);
        min + ((rand % diff) as u128)
    }

    /// Generate a random u128 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u128_in_range(g: &mut RandomGenerator, min: u128, max: u128): u128 {
        u128_in_range(g, min, max, 24)
    }

    //// Generate a random u64 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u64_in_range(g: &mut RandomGenerator, min: u64, max: u64): u64 {
        (u128_in_range(g, (min as u128), (max as u128), 16) as u64)
    }

    /// Generate a random u32 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u32_in_range(g: &mut RandomGenerator, min: u32, max: u32): u32 {
        (u128_in_range(g, (min as u128), (max as u128), 12) as u32)
    }

    /// Generate a random u16 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u16_in_range(g: &mut RandomGenerator, min: u16, max: u16): u16 {
        (u128_in_range(g, (min as u128), (max as u128), 10) as u16)
    }

    /// Generate a random u8 in [min, max] (with a bias of 2^{-64}).
    public fun generate_u8_in_range(g: &mut RandomGenerator, min: u8, max: u8): u8 {
        (u128_in_range(g, (min as u128), (max as u128), 9) as u8)
    }


    //
    // Helper functions for testing.
    //

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext) {
        create(ctx);
    }

    #[test_only]
    public fun update_randomness_state_for_testing(
        self: &mut Random,
        new_round: u64,
        new_bytes: vector<u8>,
        new_max_size: u64,
        ctx: &TxContext,
    ) {
        update_randomness_state(self, new_round, new_bytes, new_max_size, ctx);
    }

    #[test_only]
    public fun get_latest_round(self: &Random): u64 {
        let rounds = load_rounds(self);
        rounds.latest_round
    }

    #[test_only]
    public fun generator_seed(r: &RandomGenerator): &vector<u8> {
        &r.seed
    }

    #[test_only]
    public fun generator_counter(r: &RandomGenerator): u16 {
        r.counter
    }

    #[test_only]
    public fun generator_buffer(r: &RandomGenerator): &vector<u8> {
        &r.buffer
    }

}
