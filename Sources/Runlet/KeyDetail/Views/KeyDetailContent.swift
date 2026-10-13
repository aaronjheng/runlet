import SwiftUI

// MARK: - Key Detail Content

/// Type-specific detail bodies for `KeyDetailView` (string/hash/list/set/zset
/// plus the generic fallback). Kept in an extension of the main view so the
/// state properties stay owned by `KeyDetailView.swift`.
extension KeyDetailView {
    @ViewBuilder
    func detailContent(key: RedisKeyEntry) -> some View {
        @Bindable var tab = tab

        switch tab.keyType {
        case "string":
            StringDetailView(
                key: key.key,
                value: tab.keyDetail,
                format: $tab.stringValueFormat,
                onSave: { value in
                    guardProductionWrite(
                        title: "Overwrite Value?",
                        message: "This will overwrite the value of \"\(key.key)\" on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateStringValue(key: key.key, value: value)
                            await tab.refreshSelectedKey()
                        }
                    }
                }
            )

        case "hash":
            HashDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                searchText: tab.keyDetailSearchText,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onSearch: { text in
                    Task { await tab.searchSelectedKeyDetail(text) }
                },
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onAddField: { showingAddHashField = true },
                onSaveField: { field, value in
                    guardProductionWrite(
                        title: "Overwrite Field?",
                        message: "This will overwrite field \"\(field)\" of \"\(key.key)\""
                            + "on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateHashField(key: key.key, field: field, value: value)
                            await tab.refreshSelectedKey()
                        }
                    }
                },
                onDeleteField: { field in
                    Task {
                        await tab.deleteHashField(key: key.key, field: field)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddHashField) {
                AddHashFieldSheet(
                    onSave: { pairs in
                        showingAddHashField = false
                        guardProductionWrite(
                            title: "Add Fields?",
                            message: "This will add \(pairs.count) fields to \"\(key.key)\" on"
                                + "a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Fields"
                        ) {
                            Task {
                                await tab.addHashFields(key: key.key, pairs: pairs)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddHashField = false }
                )
                .presentationSizing(.form)
            }

        case "list":
            ListDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                order: tab.keyDetailOrder,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onOrderChange: { order in
                    Task { await tab.updateSelectedKeyOrder(order) }
                },
                onAddElement: { showingAddListElement = true },
                onSaveElement: { index, value in
                    guardProductionWrite(
                        title: "Overwrite Element?",
                        message: "This will overwrite element \(index) of \"\(key.key)\""
                            + "on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateListElement(key: key.key, index: index, value: value)
                            await tab.refreshSelectedKey()
                        }
                    }
                },
                onDeleteElement: { index, _ in
                    Task {
                        await tab.deleteListElement(key: key.key, index: index)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddListElement) {
                AddListElementSheet(
                    onSave: { values, position in
                        showingAddListElement = false
                        guardProductionWrite(
                            title: "Add Elements?",
                            message:
                                "This will add \(values.count) elements to \"\(key.key)\" on a production server. "
                                + "This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Elements"
                        ) {
                            Task {
                                await tab.addListElements(key: key.key, values: values, tail: position == .tail)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddListElement = false }
                )
                .presentationSizing(.form)
            }

        case "set":
            SetDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                searchText: tab.keyDetailSearchText,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onSearch: { text in
                    Task { await tab.searchSelectedKeyDetail(text) }
                },
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onAddMember: { showingAddSetMember = true },
                onDeleteMember: { member in
                    Task {
                        await tab.deleteSetMember(key: key.key, member: member)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddSetMember) {
                AddSetMemberSheet(
                    onSave: { members in
                        showingAddSetMember = false
                        guardProductionWrite(
                            title: "Add Members?",
                            message: "This will add \(members.count) members to \"\(key.key)\" on"
                                + "a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Members"
                        ) {
                            Task {
                                await tab.addSetMembers(key: key.key, members: members)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddSetMember = false }
                )
                .presentationSizing(.form)
            }

        case "zset":
            ZSetDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                searchText: tab.keyDetailSearchText,
                order: tab.keyDetailOrder,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onSearch: { text in
                    Task { await tab.searchSelectedKeyDetail(text) }
                },
                onOrderChange: { order in
                    Task { await tab.updateSelectedKeyOrder(order) }
                },
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onAddMember: { showingAddZSetMember = true },
                onSaveMember: { member, score in
                    guardProductionWrite(
                        title: "Overwrite Score?",
                        message: "This will overwrite the score of member \"\(member)\" in"
                            + "\"\(key.key)\" on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateZSetScore(key: key.key, member: member, score: score)
                            await tab.refreshSelectedKey()
                        }
                    }
                },
                onDeleteMember: { member in
                    Task {
                        await tab.deleteZSetMember(key: key.key, member: member)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddZSetMember) {
                AddZSetMemberSheet(
                    onSave: { members in
                        showingAddZSetMember = false
                        guardProductionWrite(
                            title: "Add Members?",
                            message: "This will add \(members.count) members to \"\(key.key)\" on"
                                + "a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Members"
                        ) {
                            Task {
                                await tab.addZSetMembers(key: key.key, members: members)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddZSetMember = false }
                )
                .presentationSizing(.form)
            }

        case "array":
            ArrayDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                order: tab.keyDetailOrder,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onOrderChange: { order in
                    Task { await tab.updateSelectedKeyOrder(order) }
                },
                onAddElement: { showingAddArrayElement = true },
                onSaveElement: { index, value in
                    guardProductionWrite(
                        title: "Overwrite Element?",
                        message: "This will overwrite element \(index) of \"\(key.key)\""
                            + "on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateArrayElement(key: key.key, index: index, value: value)
                            await tab.refreshSelectedKey()
                        }
                    }
                },
                onDeleteElement: { index, _ in
                    Task {
                        await tab.deleteArrayElement(key: key.key, index: index)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddArrayElement) {
                AddArrayElementSheet(
                    onSave: { entries in
                        showingAddArrayElement = false
                        let allExplicit = entries.allSatisfy { $0.index != nil }
                        let allAppend = entries.allSatisfy { $0.index == nil }
                        let indexDescription: String
                        if allExplicit {
                            indexDescription = "explicit index\(entries.count > 1 ? "es" : "")"
                        } else if allAppend {
                            indexDescription = "the end"
                        } else {
                            indexDescription = "mixed index/append positions"
                        }
                        guardProductionWrite(
                            title: "Add Elements?",
                            message: "This will add \(entries.count) elements at \(indexDescription) to \"\(key.key)\" on"
                                + "a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Elements"
                        ) {
                            Task {
                                await tab.addArrayElements(key: key.key, entries: entries)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddArrayElement = false }
                )
                .presentationSizing(.form)
            }

        default:
            if tab.keyDetailRows.isEmpty {
                emptyValueView
            } else {
                genericRowsView
            }
        }
    }
}
