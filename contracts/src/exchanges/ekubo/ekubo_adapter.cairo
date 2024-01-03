use openzeppelin::token::erc20::interface::IERC20Dispatcher;
use starknet::{ContractAddress, ClassHash};


#[derive(Copy, Drop, Serde)]
struct EkuboLaunchParameters {
    token_address: ContractAddress,
    counterparty_address: ContractAddress,
    fee: u128,
    tick_spacing: u128,
    // the sign of the starting tick and the boudns is determined by the address of the deployed token contract
    starting_tick: u128,
    // The LP providing bound, upper/lower determined by the address of the LPed tokens
    bound: u128,
}

#[starknet::component]
mod EkuboComponent {
    use ERC20Component::InternalTrait as ERC20Internal; // required to use internals of ERC20Component
    use OwnableComponent::Ownable; // required to use internals of OwnableComponent
    use array::ArrayTrait;
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use debug::PrintTrait;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::ERC20Component;
    use openzeppelin::token::erc20::interface::IERC20CamelOnly;
    use openzeppelin::token::erc20::interface::{
        IERC20, IERC20Metadata, ERC20ABIDispatcher, ERC20ABIDispatcherTrait
    };
    use starknet::{get_block_timestamp, ContractAddress};
    use super::EkuboLaunchParameters;
    use unruggable::exchanges::ekubo::launchpad::{ILaunchpadDispatcher, ILaunchpadDispatcherTrait,};
    use unruggable::errors;
    use unruggable::locker::{ILockManagerDispatcher, ILockManagerDispatcherTrait};
    use unruggable::tokens::interface::{
        IUnruggableAdditional, IUnruggableMemecoinCamel, IUnruggableMemecoinSnake
    };

    #[storage]
    struct Storage {}


    #[embeddable_as(EkuboAdapterImpl)]
    impl EkuboAdapter<
        TContractState,
        +HasComponent<TContractState>,
        // The contract embedding this componenet
        // must also embed ERC20Component
        impl ERC20: ERC20Component::HasComponent<TContractState>,
        impl Ownable: OwnableComponent::HasComponent<TContractState>,
        +IUnruggableMemecoinCamel<TContractState>,
        +IUnruggableMemecoinSnake<TContractState>,
        +IUnruggableAdditional<TContractState>,
        +Drop<TContractState>
    > of unruggable::exchanges::IAmmAdapter<ComponentState<TContractState>> {
        fn create_and_add_liquidity(
            ref self: ComponentState<TContractState>,
            exchange_address: ContractAddress,
            token_address: ContractAddress,
            counterparty_address: ContractAddress,
            unlock_time: u64,
            mut additional_parameters: Span<felt252>,
        ) -> Span<felt252> {
            let ekubo_launch_params: EkuboLaunchParameters = Serde::deserialize(
                ref additional_parameters
            )
                .expect('Invalid ekubo add liq params');

            // This component is made to be embedded inside the memecoin contract. In order to access
            // its functions, we need to get a mutable reference to the memecoin contract.
            let mut memecoin = self.get_contract_mut();

            // As the memecoin contract embeds ERC20Component, we need to get a mutable reference to
            // its ERC20 component in order to access its internal functions (such as _approve).
            let mut memecoin_erc20 = get_dep_component_mut!(ref self, ERC20);
            let mut memecoin_ownable = get_dep_component_mut!(ref self, Ownable);

            let this_address = starknet::get_contract_address();
            let caller_address = starknet::get_caller_address();
            let counterparty_token = ERC20ABIDispatcher { contract_address: counterparty_address, };
            let ekubo_launchpad = ILaunchpadDispatcher { contract_address: exchange_address };
            assert(ekubo_launchpad.contract_address.is_non_zero(), errors::EXCHANGE_ADDRESS_ZERO);

            // Transfer the tokens to the launchpad contract.
            let memecoin_balance = memecoin.balanceOf(this_address);
            let counterparty_token_balance = counterparty_token.balanceOf(this_address);

            // Using internal transfer here as memecoin_erc20 is the component of THIS same contract
            // so the caller_address is not this_address - unlike counterparty_token which is an external call.
            memecoin_erc20
                ._transfer(this_address, ekubo_launchpad.contract_address, memecoin_balance);

            let nft_id = ekubo_launchpad.launch_token(ekubo_launch_params);
            //TODO: handle the NFT representing the LP

            // We make sure that no liquidity was returned to the depositor.
            // Otherwise, the LP deposit parameters were wrong.
            memecoin_erc20.balanceOf(this_address).print();
            assert(memecoin_erc20.balanceOf(this_address) == 0, 'ekubo has returned memecoin');

            // Any counterparty tokens that were deposited in this contract must be returned to the caller
            // as no counterparty is required to launch a memecoin with Ekubo.
            self.clear(counterparty_address);
            assert(counterparty_token.balanceOf(this_address) == 0, 'counterparty leftovers');

            //TODO: lock tokens
            // assert(
            //     memecoin.balanceOf(ekubo_launchpad.contract_address) == memecoin_balance,
            //     'add liquidity meme failed'
            // );
            // assert(
            //     counterparty_token
            //         .balanceOf(ekubo_launchpad.contract_address) == counterparty_token_balance,
            //     'add liq counterparty failed'
            // );

            // // Lock LP tokens
            // let lock_manager_address = memecoin.lock_manager_address();
            // let lock_manager = ILockManagerDispatcher { contract_address: lock_manager_address };
            // pair.approve(lock_manager_address, liquidity_received);
            // let locked_address = lock_manager
            //     .lock_tokens(
            //         token: pair_address,
            //         amount: liquidity_received,
            //         :unlock_time,
            //         withdrawer: memecoin_ownable.owner(),
            //     );
            // assert(pair.balanceOf(locked_address) == liquidity_received, 'lock failed');

            let mut return_data = Default::default();
            Serde::serialize(@nft_id, ref return_data);
            return_data.span()
        }
    }

    #[generate_trait]
    impl InternalImpl<TContractState> of InternalTrait<TContractState> {
        fn clear(ref self: ComponentState<TContractState>, token: ContractAddress) {
            let caller = starknet::get_caller_address();
            let this = starknet::get_contract_address();
            let token = ERC20ABIDispatcher { contract_address: token, };
            token.transfer(caller, token.balanceOf(this));
        }
    }
}
